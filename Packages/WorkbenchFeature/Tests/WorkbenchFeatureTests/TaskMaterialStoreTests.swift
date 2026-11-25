import Foundation
import Darwin
import Testing
@testable import WorkbenchFeature

private final class MaterialTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: value) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
private final class MaterialStoreReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func observe(_ kind: TaskMaterialReadKind, _ amount: Int) { if kind == .payload { lock.withLock { bytes += amount } } }
    var payloadBytes: Int { lock.withLock { bytes } }
}

struct TaskMaterialStoreTests {
    private func fixture() throws -> URL {
        try TaskMaterialTestFixtures.directory("Store")
    }
    private func key() -> TaskMaterialKey { .init(receiptStore: .ai, invocationID: UUID(), receiptRecordIdentity: UUID()) }
    private func save(_ input: String, key: TaskMaterialKey, store: TaskMaterialStore, replacing: TaskMaterialVersion? = nil) async throws -> TaskMaterialHandle {
        let check = try await store.prepareWrite(key, expected: replacing)
        return try await store.save(.init(input: input), using: check)
    }

    @Test func defaultOffDoesNotCreateStorageAndRestartIndexesOnlyHeaders() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("materials"), log = MaterialStoreReadLog(), clock = MaterialTestClock(), id = key()
        let store = try TaskMaterialStore(directory: directory, clock: clock.now, observeRead: log.observe)
        #expect(try await store.inventory().handles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await #expect(throws: TaskMaterialError.permissionDenied) { try await store.prepareWrite(id, expected: nil) }
        store.fence.setEnabled(true)
        let handle = try await save("e\u{301}", key: id, store: store)
        await store.shutdown()
        let restarted = try TaskMaterialStore(directory: directory, clock: clock.now, observeRead: log.observe)
        let index = try await restarted.inventory()
        #expect(index.handles.count == 1 && log.payloadBytes == 0)
        await #expect(throws: TaskMaterialError.permissionDenied) { try await restarted.prepareWrite(id, expected: handle.version) }
        let current = try #require(index.handles.first)
        let body = try await restarted.read(current, expectedGeneration: restarted.fence.current.generation)
        #expect(body.input?.utf8.elementsEqual("e\u{301}".utf8) == true && log.payloadBytes > 0)
        await restarted.shutdown()
    }

    @Test func independentCASRejectsOldAndDuplicateTickets() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) }), id = key()
        store.fence.setEnabled(true)
        let a = try await store.prepareWrite(id, expected: nil), b = try await store.prepareWrite(id, expected: nil)
        let first = try await store.save(.init(input: "first"), using: a)
        await #expect(throws: TaskMaterialError.staleCheck) { try await store.save(.init(input: "duplicate"), using: a) }
        await #expect(throws: TaskMaterialError.changed) { try await store.save(.init(input: "old absence"), using: b) }
        let second = try await save("second", key: id, store: store, replacing: first.version)
        #expect(second.version.identity == first.version.identity && second.version.revision == 2)
        await #expect(throws: TaskMaterialError.changed) { try await store.read(first, expectedGeneration: store.fence.current.generation) }
        await store.shutdown()
    }

    @Test func replacementReservesTheFullTemporaryBodyBeforeWriting() async throws {
        let root = try TaskMaterialTestFixtures.directory("TemporaryBudget"); defer { try? FileManager.default.removeItem(at: root) }
        var policy = TaskMaterialPolicy(); policy.maximumTotalBytes = 2_048; policy.maximumRecordBytes = 2_048
        let store = try TaskMaterialStore(directory: root, policy: policy, clock: { Date(timeIntervalSince1970: 1_000) })
        store.fence.setEnabled(true)
        let id = key(), old = try await save(String(repeating: "a", count: 900), key: id, store: store)
        let check = try await store.prepareWrite(id, expected: old.version)
        await #expect(throws: TaskMaterialError.capacity) { try await store.save(.init(input: String(repeating: "b", count: 900)), using: check) }
        let after = try await store.inventory()
        #expect(after.handles.count == 1 && after.handles.first?.version == old.version)
        #expect(after.isComplete && !after.pendingWrite && after.managedTemporaryNames.isEmpty)
        #expect(try await store.read(old, expectedGeneration: store.fence.current.generation).input == String(repeating: "a", count: 900))
        await store.shutdown()
    }

    @Test func capacityRefusalDoesNotDeleteExistingMaterial() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = TaskMaterialPolicy(); policy.maximumCount = 1; policy.maximumTotalBytes = 4_096; policy.maximumRecordBytes = 4_096
        let store = try TaskMaterialStore(directory: root, policy: policy, clock: { Date(timeIntervalSince1970: 1_000) }), id = key()
        store.fence.setEnabled(true)
        let first = try await save("keep unchanged", key: id, store: store)
        let before = try Data(contentsOf: root.appendingPathComponent(id.fileName))
        await #expect(throws: TaskMaterialError.capacity) { try await save("another", key: key(), store: store) }
        #expect(try Data(contentsOf: root.appendingPathComponent(id.fileName)) == before)
        #expect(try await store.read(first, expectedGeneration: store.fence.current.generation).input == "keep unchanged")
        await store.shutdown()
    }

    @Test func deletionRecreationChangesMaterialBirthAndKeepsOtherReceiptBirthSeparate() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) }), id = key()
        store.fence.setEnabled(true)
        let first = try await save("first", key: id, store: store)
        let removed = await store.delete(first); #expect(removed.isComplete)
        let next = try await save("new birth", key: id, store: store)
        #expect(next.version.revision == 1 && next.version.identity != first.version.identity)
        let other = TaskMaterialKey(receiptStore: .ai, invocationID: id.invocationID, receiptRecordIdentity: UUID())
        #expect(try await store.inspect(other) == nil)
        await #expect(throws: TaskMaterialError.changed) { try await store.read(first, expectedGeneration: store.fence.current.generation) }
        await store.shutdown()
    }

    @Test func partialClearIsHiddenAndDurableIntentContinuesAfterRestart() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let failed = key(), removed = key(), log = MaterialStoreReadLog()
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) }, fault: { role, point, name in
            role == .body && point == .beforeDelete && name == failed.fileName ? EACCES : nil
        }, observeRead: log.observe)
        store.fence.setEnabled(true)
        let retained = try await save("private synthetic failure", key: failed, store: store)
        _ = try await save("private synthetic removable", key: removed, store: store)
        let partial = await store.clear()
        #expect(!partial.isComplete && partial.pendingDeletion && partial.remainingNames == [failed.fileName])
        #expect(partial.removedNames == [removed.fileName])
        #expect(try await store.inventory().handles.isEmpty)
        await #expect(throws: TaskMaterialError.pendingDeletion) { try await store.read(retained, expectedGeneration: store.fence.current.generation) }
        await store.shutdown()
        let restarted = try TaskMaterialStore(directory: root, observeRead: log.observe)
        let result = await restarted.resumeDeletion()
        #expect(result.isComplete && result.removedNames == [failed.fileName])
        #expect(try await restarted.inventory().handles.isEmpty && log.payloadBytes == 0)
        await restarted.shutdown()
    }

    @Test func oldReadCannotPublishAfterContentGenerationChanges() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fence = TaskMaterialFence()
        let store = try TaskMaterialStore(directory: root, fence: fence, clock: { Date(timeIntervalSince1970: 1_000) }, observeRead: { kind, _ in
            if kind == .payload { fence.invalidateContent() }
        })
        fence.setEnabled(true)
        let handle = try await save("synthetic", key: key(), store: store)
        let before = fence.current.generation
        await #expect(throws: TaskMaterialError.staleCheck) { try await store.read(handle, expectedGeneration: before) }
        await store.shutdown()
    }

    @Test func revokedWriteClosesItsControlIntentWithoutSavingBody() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fence = TaskMaterialFence(), id = key()
        let store = try TaskMaterialStore(directory: root, fence: fence, clock: { Date(timeIntervalSince1970: 1_000) }, fault: { role, point, _ in
            if role == .body, point == .beforeRename { fence.setEnabled(false) }; return nil
        })
        fence.setEnabled(true)
        await #expect(throws: TaskMaterialError.permissionDenied) { try await save("must not persist", key: id, store: store) }
        let index = try await store.inventory()
        #expect(index.handles.isEmpty && !index.pendingWrite && index.managedTemporaryNames.isEmpty)
        await store.shutdown()
    }

    @Test func maintenanceUsesCapturedHandlesAndDoesNotEraseLaterNewOrUpdatedMaterial() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) }), a = key(), b = key()
        store.fence.setEnabled(true)
        let original = try await save("original", key: a, store: store)
        let inventory = try await store.inventory()
        _ = try await save("new task", key: b, store: store)
        _ = try await save("new version", key: a, store: store, replacing: original.version)
        let result = await store.maintain(inventory, validOwners: [])
        #expect(result.isComplete)
        #expect(try await store.inventory().handles.count == 2)
        await store.shutdown()
    }

    @Test func expiredMaterialIsRemovedWithoutReadingPayload() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var policy = TaskMaterialPolicy(); policy.retentionInterval = 10
        let clock = MaterialTestClock(), log = MaterialStoreReadLog(), id = key()
        let store = try TaskMaterialStore(directory: root, policy: policy, clock: clock.now, observeRead: log.observe)
        store.fence.setEnabled(true)
        let handle = try await save("expired", key: id, store: store), inventory = try await store.inventory()
        clock.advance(10)
        await #expect(throws: TaskMaterialError.expired) { try await store.read(handle, expectedGeneration: store.fence.current.generation) }
        let report = await store.maintain(inventory, validOwners: [id])
        #expect(report.isComplete && report.removedNames == [id.fileName] && log.payloadBytes == 0)
        await store.shutdown()
    }
}
