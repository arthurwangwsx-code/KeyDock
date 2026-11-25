import Foundation
import Darwin
import Testing
@testable import WorkbenchFeature

struct TaskMaterialRecoveryTests {
    private func save(_ input: String, key: TaskMaterialKey, store: TaskMaterialStore) async throws -> TaskMaterialHandle {
        let check = try await store.prepareWrite(key, expected: nil)
        return try await store.save(.init(input: input), using: check)
    }
    @Test func orphanTemporaryPlaintextKeepsPendingWriteUntilExplicitKeyClear() async throws {
        let root = try TaskMaterialTestFixtures.directory("Recovery"); defer { try? FileManager.default.removeItem(at: root) }
        let key = TaskMaterialTestFixtures.key()
        let temporary = ".material-v1-" + String(key.fileName.dropLast(".kdmaterial".count)) + "-" + UUID().uuidString.lowercased() + ".tmp"
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) }, fault: { role, point, _ in
            if role == .body, point == .beforeRename {
                let location = root.appendingPathComponent(temporary)
                try? Data("synthetic orphan plaintext".utf8).write(to: location)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
                return EIO
            }
            return nil
        })
        store.fence.setEnabled(true)
        await #expect(throws: TaskMaterialError.io(EIO)) { try await save("not committed synthetic input", key: key, store: store) }
        let inventory = try await store.inventory()
        #expect(inventory.pendingWrite && inventory.managedTemporaryNames == [temporary] && inventory.handles.isEmpty)
        let control = try Data(contentsOf: root.appendingPathComponent(TaskMaterialFiles.controlName))
        #expect(!String(decoding: control, as: UTF8.self).contains("not committed synthetic input"))
        await #expect(throws: TaskMaterialError.recoveryRequired) { try await store.prepareWrite(key, expected: nil) }
        let report = await store.clearOwners([key])
        #expect(report.isComplete && report.removedNames == [temporary])
        let cleared = try await store.inventory()
        #expect(cleared.isComplete && cleared.handles.isEmpty)
        await store.shutdown()
    }

    @Test func corruptControlHidesBodyAndExplicitFullClearCanReplaceIt() async throws {
        let root = try TaskMaterialTestFixtures.directory("Control"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) })
        store.fence.setEnabled(true)
        let handle = try await save("synthetic retained content", key: TaskMaterialTestFixtures.key(), store: store)
        try Data("{\"formatVersion\":99}".utf8).write(to: root.appendingPathComponent(TaskMaterialFiles.controlName))
        let inventory = try await store.inventory()
        #expect(inventory.pendingDeletion && inventory.handles.isEmpty && inventory.unsafeNames.contains(TaskMaterialFiles.controlName))
        await #expect(throws: TaskMaterialError.malformedControl) { try await store.read(handle, expectedGeneration: store.fence.current.generation) }
        let result = await store.clear()
        #expect(result.isComplete && result.removedNames == [handle.key.fileName])
        #expect(try await store.inventory().isComplete)
        await store.shutdown()
    }

    @Test func foreignEntriesAreRetainedAndPartialClearNeverClaimsAnEmptyStore() async throws {
        let root = try TaskMaterialTestFixtures.directory("Unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) })
        store.fence.setEnabled(true)
        _ = try await save("synthetic", key: TaskMaterialTestFixtures.key(), store: store)
        let foreign = root.appendingPathComponent("keep-unknown.txt")
        try Data("keep unchanged".utf8).write(to: foreign)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreign.path)
        let report = await store.clear()
        #expect(!report.isComplete && report.didInspectRemaining && report.pendingDeletion)
        #expect(report.remainingNames == ["keep-unknown.txt"] && report.failedNames == ["keep-unknown.txt"])
        #expect(try Data(contentsOf: foreign) == Data("keep unchanged".utf8))
        try FileManager.default.removeItem(at: foreign)
        #expect(await store.resumeDeletion().isComplete)
        await store.shutdown()
    }

    @Test func postRenameFailureDoesNotPretendThePreviousFileSurvived() async throws {
        let root = try TaskMaterialTestFixtures.directory("Uncertain"); defer { try? FileManager.default.removeItem(at: root) }
        let key = TaskMaterialTestFixtures.key()
        let store = try TaskMaterialStore(directory: root, clock: { Date(timeIntervalSince1970: 1_000) }, fault: { role, point, _ in
            role == .body && point == .afterRename ? EIO : nil
        })
        store.fence.setEnabled(true)
        await #expect(throws: TaskMaterialError.durabilityUncertain(EIO)) { try await save("present after uncertain rename", key: key, store: store) }
        let inventory = try await store.inventory(), current = try #require(inventory.handles.first)
        #expect(!inventory.pendingWrite)
        #expect(try await store.read(current, expectedGeneration: store.fence.current.generation).input == "present after uncertain rename")
        await #expect(throws: TaskMaterialError.changed) { try await store.prepareWrite(key, expected: nil) }
        await store.shutdown()
    }

    @Test func permissionABAAndForeignActorsCannotReuseWriteChecks() async throws {
        let a = try TaskMaterialTestFixtures.directory("A"), b = try TaskMaterialTestFixtures.directory("B")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = try TaskMaterialStore(directory: a, clock: { Date(timeIntervalSince1970: 1_000) })
        let other = try TaskMaterialStore(directory: b, clock: { Date(timeIntervalSince1970: 1_000) })
        first.fence.setEnabled(true); other.fence.setEnabled(true)
        let key = TaskMaterialTestFixtures.key(), old = try await first.prepareWrite(key, expected: nil)
        await #expect(throws: TaskMaterialError.foreignCheck) { try await other.save(.init(input: "foreign"), using: old) }
        first.fence.setEnabled(false); first.fence.setEnabled(true)
        await #expect(throws: TaskMaterialError.permissionDenied) { try await first.save(.init(input: "ABA"), using: old) }
        let firstIndex = try await first.inventory(), otherIndex = try await other.inventory()
        #expect(firstIndex.handles.isEmpty && otherIndex.handles.isEmpty)
        await first.shutdown(); await other.shutdown()
    }

    @Test func malformedNestedControlCannotCarryUnknownFields() throws {
        let pending = TaskMaterialPendingWrite(key: TaskMaterialTestFixtures.key(), proposed: .init(identity: UUID(), revision: 1),
            previous: nil, payloadSHA256: String(repeating: "a", count: 64), fileBytes: 1_000)
        let bytes = try TaskMaterialControl(formatVersion: 1, epoch: UUID(), pendingWrite: pending).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var write = try #require(object["pendingWrite"] as? [String: Any])
        var key = try #require(write["key"] as? [String: Any]); key["runtimeGrant"] = "not allowed"; write["key"] = key; object["pendingWrite"] = write
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: TaskMaterialError.malformedControl) { try TaskMaterialControl.decode(malformed) }
    }
}
