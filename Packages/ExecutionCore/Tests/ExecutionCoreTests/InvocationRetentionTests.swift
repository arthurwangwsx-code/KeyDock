import Darwin
import Foundation
import Testing
@testable import ExecutionCore

private final class ReceiptTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ seconds: TimeInterval) { value = Date(timeIntervalSince1970: seconds) }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ seconds: TimeInterval) { lock.lock(); value = Date(timeIntervalSince1970: seconds); lock.unlock() }
}

/// 全部数据都在每项测试独占的临时目录中，不访问真实应用数据。
@Suite(.serialized, .timeLimit(.minutes(1))) struct InvocationRetentionTests {
    private struct Archive: Codable { let version: Int; let receipts: [InvocationReceipt] }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Receipt-Retention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func file(_ directory: URL) -> URL { directory.appendingPathComponent("invocations.json") }
    private func seed(_ values: [InvocationReceipt], in directory: URL) throws -> Data {
        let bytes = try JSONEncoder().encode(Archive(version: 1, receipts: values))
        try bytes.write(to: file(directory)); return bytes
    }
    private func terminal(_ id: UUID, at seconds: TimeInterval, name: String = "Synthetic") -> InvocationReceipt {
        .init(id: id, name: name, state: .succeeded, startedAt: Date(timeIntervalSince1970: seconds), finishedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func ninetyDayBoundaryIsStrictAndRunningIntentsAreNeverExpired() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ReceiptTestClock(1_000), id = UUID(), running = UUID()
        let store = try InvocationStore(directory: folder,
            retention: .init(maxFinishedAge: 10), clock: { clock.now() })
        try await store.begin(id: id, name: "Synthetic finished")
        try await store.finish(id: id, result: .init(state: .succeeded)); await store.releaseProtection(for: id)
        try await store.begin(id: running, name: "Synthetic running")
        clock.set(1_010)
        #expect(await store.maintain().removedIDs.isEmpty)
        clock.set(1_010.01)
        let report = await store.maintain()
        #expect(report.removedIDs == [id] && report.remainingIDs == [running] && report.failure == nil)
        #expect(await store.list().first?.state == .running)
    }

    @Test func directorySymbolicLinkIsRejectedWithoutChangingItsTarget() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = parent.appendingPathComponent("owned-original"), link = parent.appendingPathComponent("owned-link")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let bytes = try seed([terminal(UUID(), at: Date().timeIntervalSince1970)], in: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: InvocationStoreError.invalidDirectory) { _ = try InvocationStore(directory: link) }
        #expect(try Data(contentsOf: file(original)) == bytes)
    }

    @Test func countEvictionIsDeterministicAndSuppliedProtectionIsRespected() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ReceiptTestClock(2_000)
        let ids = (1...3).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let store = try InvocationStore(directory: folder,
            retention: .init(maxFinishedCount: 1), clock: { clock.now() })
        for id in ids {
            try await store.begin(id: id, name: "Synthetic tie")
            try await store.finish(id: id, result: .init(state: .succeeded)); await store.releaseProtection(for: id)
        }
        // begin/finish不会在消费者尚未完成时隐式删历史。
        #expect(await store.list().count == 3)
        let report = await store.maintain(protecting: [ids[0]])
        #expect(report.removedIDs == [ids[1], ids[2]] && report.remainingIDs == [ids[0]])
        #expect(report.protectedIDs == [ids[0]] && report.limitsSatisfied)
    }

    @Test func staleProtectionSnapshotCannotDeleteANewFinishedButUnconsumedInvocation() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try InvocationStore(directory: folder, retention: .init(maxFinishedCount: 0))
        let staleSnapshot: Set<UUID> = [], id = UUID()
        try await store.begin(id: id, name: "Synthetic pending consumer")
        try await store.finish(id: id, result: .init(state: .succeeded))
        await store.acknowledgeRecovery()
        #expect(await store.maintain(protecting: staleSnapshot).remainingIDs == [id])
        let kept = await store.clearFinished(onlyIDs: [id], excluding: staleSnapshot)
        #expect(kept.removedIDs.isEmpty && kept.remainingIDs == [id] && kept.protectedIDs == [id])
        await store.releaseProtection(for: id)
        #expect(await store.maintain().removedIDs == [id])
    }

    @Test func byteLimitPrunesOldestTerminalMetadataOnBoundedLegacyLoad() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let values = (0..<20).map { terminal(UUID(), at: 1_000 + Double($0), name: String(repeating: "x", count: 120)) }
        let before = try seed(values, in: folder)
        #expect(before.count > 600)
        let store = try InvocationStore(directory: folder,
            retention: .init(maxFileBytes: 600, maxLoadBytes: 16_384), clock: { Date(timeIntervalSince1970: 10_000) })
        let remaining = await store.list()
        #expect(!remaining.isEmpty && remaining.count < values.count)
        #expect(remaining.contains { $0.id == values.last?.id })
        #expect(try Data(contentsOf: file(folder)).count <= 600)
        let attributes = try FileManager.default.attributesOfItem(atPath: file(folder).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func recoveredUnknownIntentSurvivesUntilExplicitRecoveryAcknowledgement() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let original = try seed([.init(id: id, name: "Synthetic old intent", state: .running,
            startedAt: Date(timeIntervalSince1970: 1), message: "terminal.handoffIntent")], in: folder)
        let store = try InvocationStore(directory: folder,
            retention: .init(maxFinishedCount: 0, maxFileBytes: 128, maxLoadBytes: 4_096))
        let recovered = try #require(await store.list().first)
        #expect(recovered.state == .interrupted && recovered.message == "terminal.handoffUnknown")
        // 不能为了满足预算，在首次恢复前毁掉旧intent；保留原文件待宿主展示后维护。
        #expect(try Data(contentsOf: file(folder)) == original)
        #expect(await store.maintain().remainingIDs == [id])
        try await store.finish(id: id, result: .init(state: .succeeded))
        #expect(await store.list().first?.state == .interrupted)
        await store.acknowledgeRecovery()
        let report = await store.maintain()
        #expect(report.removedIDs == [id] && report.remainingIDs.isEmpty && report.failure == nil)
    }

    @Test func fixedClearCandidatesDoNotCaptureNewCompletionsOrDeleteRunningIntents() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try InvocationStore(directory: folder), old = UUID(), newer = UUID(), active = UUID()
        for id in [old, newer] {
            try await store.begin(id: id, name: "Synthetic fixed set")
            try await store.finish(id: id, result: .init(state: .succeeded)); await store.releaseProtection(for: id)
        }
        try await store.begin(id: active, name: "Synthetic active")
        let report = await store.clearFinished(onlyIDs: [old, active, UUID()])
        #expect(report.removedIDs == [old] && report.remainingIDs == [newer, active])
        let again = await store.clearFinished(onlyIDs: [old])
        #expect(again.removedIDs.isEmpty && again.remainingIDs == [newer, active] && again.failure == nil)
    }

    @Test func failedAtomicClearNeverClaimsDeletionAndCanBeRetried() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try InvocationStore(directory: folder), id = UUID()
        try await store.begin(id: id, name: "Synthetic clear failure")
        try await store.finish(id: id, result: .init(state: .succeeded)); await store.releaseProtection(for: id)
        let target = file(folder), backup = folder.appendingPathComponent("synthetic-preserved-index")
        try FileManager.default.moveItem(at: target, to: backup)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let failed = await store.clearFinished(onlyIDs: [id])
        #expect(failed.failure != nil && failed.removedIDs.isEmpty && failed.failedIDs == [id] && failed.remainingIDs == [id])
        #expect(await store.list().map(\.id) == [id])
        try FileManager.default.removeItem(at: target); try FileManager.default.moveItem(at: backup, to: target)
        let retried = await store.clearFinished(onlyIDs: [id])
        #expect(retried.removedIDs == [id] && retried.remainingIDs.isEmpty && retried.failure == nil)
        #expect(try JSONDecoder().decode(Archive.self, from: Data(contentsOf: target)).receipts.isEmpty)
    }

    @Test func oversizedAndSymbolicLinkInputsAreRejectedWithoutChangingTheirBytes() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let data = Data(repeating: 32, count: 513), target = file(folder)
        try data.write(to: target)
        let policy = InvocationRetentionPolicy(maxFileBytes: 128, maxLoadBytes: 512)
        #expect(throws: InvocationStoreError.loadLimitExceeded) { _ = try InvocationStore(directory: folder, retention: policy) }
        #expect(try Data(contentsOf: target) == data)
        try FileManager.default.removeItem(at: target)
        let owned = folder.appendingPathComponent("synthetic-owned-target.json")
        try data.write(to: owned)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: owned)
        #expect(throws: InvocationStoreError.invalidFile) { _ = try InvocationStore(directory: folder) }
        #expect(try Data(contentsOf: owned) == data)
    }

    @Test func capacityRejectsBeforeIntentAndReservedResultSpacePreservesNormalFinish() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let blocked = try InvocationStore(directory: folder,
            retention: .init(maxFileBytes: 1_024, maxLoadBytes: 4_096))
        await #expect(throws: InvocationStoreError.capacityExceeded) { try await blocked.begin(id: UUID(), name: "Synthetic capacity") }
        #expect(await blocked.list().isEmpty)
        let store = try InvocationStore(directory: folder,
            retention: .init(maxFileBytes: 8_192, maxLoadBytes: 8_192)), id = UUID()
        try await store.begin(id: id, name: "Synthetic reserved result")
        let control = String(UnicodeScalar(UInt32(1))!)
        try await store.finish(id: id, result: .init(state: .failed, message: String(repeating: control, count: 512)))
        #expect(await store.list().first?.state == .failed)
        #expect(try Data(contentsOf: file(folder)).count <= 8_192)
    }
}
