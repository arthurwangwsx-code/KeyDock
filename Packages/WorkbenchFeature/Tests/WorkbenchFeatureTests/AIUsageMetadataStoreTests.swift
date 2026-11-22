import Foundation
import Darwin
import Testing
@testable import WorkbenchFeature

@Suite struct AIUsageMetadataStoreTests {
    @Test func expirationUsesJSONTimeAndIncludesNinetyDayBoundary() async throws {
        let fixture = try UsageRetentionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000)
        let expired = UUID(), fresh = UUID()
        try fixture.put(expired, at: now.addingTimeInterval(-90 * 86_400))
        try fixture.put(fresh, at: now.addingTimeInterval(-60))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.file(expired).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 0)], ofItemAtPath: fixture.file(fresh).path)
        let foreign = fixture.directory.appendingPathComponent("keep.json")
        try Data("synthetic foreign file".utf8).write(to: foreign)
        let store = AIUsageMetadataStore(directory: fixture.directory, clock: { now })
        let report = await store.maintain()
        #expect(report.isComplete && report.removedIDs == [expired] && report.remainingIDs == [fresh])
        #expect(report.removedCount == 1 && report.remainingCount == 1 && report.ignoredEntryCount == 1)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(await store.read(id: expired).data == nil)
        #expect(await store.read(id: fresh).data != nil)
    }

    @Test func countAndBytesEvictOldestJSONRecordWhileKeepingNewSave() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000)
        for byteLimited in [false, true] {
            let fixture = try UsageRetentionFixture()
            defer { fixture.remove() }
            let old = UUID(), middle = UUID(), new = UUID()
            let oldData = try fixture.put(old, at: now.addingTimeInterval(-300), padding: 200)
            let middleData = try fixture.put(middle, at: now.addingTimeInterval(-200), padding: 200)
            let newData = try fixture.record(new, at: now, padding: 200)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.file(old).path)
            var policy = AIUsageRetentionPolicy()
            policy.maximumCount = byteLimited ? 100 : 2
            policy.maximumTotalBytes = byteLimited ? UInt64(middleData.count + newData.count) : 1_000_000
            let store = AIUsageMetadataStore(directory: fixture.directory, policy: policy, clock: { now })
            let result = await store.save(id: new, data: newData)
            #expect(result.stored && result.report.isComplete)
            #expect(result.report.removedIDs == [old] && result.report.remainingIDs == [middle, new])
            #expect(result.report.removedBytes == oldData.count)
            #expect(result.report.remainingBytes == middleData.count + newData.count)
            var mode = stat()
            #expect(lstat(fixture.file(new).path, &mode) == 0 && mode.st_mode & 0o777 == 0o600)
            #expect(await store.read(id: new).data == newData)
        }
    }

    @Test func corruptionBlocksImpossibleCapacityWithoutDiscardingGoodRecordsAndClearCanRemoveIt() async throws {
        let fixture = try UsageRetentionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000)
        let corrupt = UUID(), oversized = UUID(), good = UUID(), incoming = UUID()
        try Data("not valid synthetic JSON".utf8).write(to: fixture.file(corrupt))
        try Data(repeating: 65, count: 2_048).write(to: fixture.file(oversized))
        try fixture.put(good, at: now.addingTimeInterval(-10))
        var policy = AIUsageRetentionPolicy()
        policy.maximumTotalBytes = 1_024
        policy.maximumRecordBytes = 512
        let store = AIUsageMetadataStore(directory: fixture.directory, policy: policy, clock: { now })
        let report = await store.maintain()
        #expect(!report.isComplete && report.removedCount == 0)
        #expect(report.problems.contains(.malformedRecord(corrupt)))
        #expect(report.problems.contains(.oversizedRecord(oversized)))
        #expect(report.problems.contains(.capacityExceeded))
        let result = await store.save(id: incoming, data: try fixture.record(incoming, at: now))
        #expect(!result.stored && result.report.remainingIDs == [corrupt, oversized, good])
        #expect(await store.read(id: good).data != nil)
        let cleared = await store.clear()
        #expect(cleared.isComplete && cleared.removedIDs == [corrupt, oversized, good])
        #expect(cleared.remainingIDs.isEmpty && cleared.remainingBytes == 0)
    }

    @Test func explicitClearReportsPartialDeletionAndRetryUsesActualRemainingFiles() async throws {
        let fixture = try UsageRetentionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000), failed = UUID(), removed = UUID()
        try fixture.put(failed, at: now)
        try fixture.put(removed, at: now)
        let blockedName = failed.uuidString + ".json"
        let store = AIUsageMetadataStore(directory: fixture.directory, clock: { now }, removeEntry: { descriptor, name in
            if name == blockedName { throw UsageRetentionTestError.syntheticDenied }
            guard unlinkat(descriptor, name, 0) == 0 else { throw UsageRetentionTestError.syntheticDenied }
        })
        let partial = await store.clear()
        #expect(!partial.isComplete && partial.removedIDs == [removed] && partial.remainingIDs == [failed])
        #expect(partial.failedIDs == [failed] && partial.problems.contains(.deletionFailed(failed)))
        #expect(partial.removedCount == 1 && partial.remainingCount == 1)
        let retried = await AIUsageMetadataStore(directory: fixture.directory).clear()
        #expect(retried.isComplete && retried.removedIDs == [failed] && retried.remainingCount == 0)
    }

    @Test func managedSymlinkAndDirectorySymlinkNeverReadOverwriteOrDeleteTheirTarget() async throws {
        let fixture = try UsageRetentionFixture()
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel.json"), original = Data("synthetic target stays".utf8)
        try original.write(to: sentinel)
        let id = UUID(), now = Date(timeIntervalSinceReferenceDate: 20_000_000)
        try FileManager.default.createSymbolicLink(at: fixture.file(id), withDestinationURL: sentinel)
        let store = AIUsageMetadataStore(directory: fixture.directory, clock: { now })
        let read = await store.read(id: id)
        #expect(read.data == nil && read.problem == .unsafeEntry(id))
        let write = await store.save(id: id, data: try fixture.record(id, at: now))
        #expect(!write.stored && write.report.problems.contains(.unsafeEntry(id)))
        let clear = await store.clear()
        #expect(!clear.isComplete && clear.remainingIDs == [id] && clear.removedCount == 0)
        #expect(try Data(contentsOf: sentinel) == original)
        let alias = fixture.base.appendingPathComponent("usage-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let redirected = AIUsageMetadataStore(directory: alias, clock: { now })
        #expect(await redirected.save(id: id, data: try fixture.record(id, at: now)).stored == false)
        #expect(await redirected.clear().isComplete == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel.json"])
    }

    @Test func incomingOversizeBadIdentityAndExpiredRecordAreRejectedWithoutReplacingExistingMetadata() async throws {
        let fixture = try UsageRetentionFixture()
        defer { fixture.remove() }
        let id = UUID(), now = Date(timeIntervalSinceReferenceDate: 20_000_000)
        let original = try fixture.put(id, at: now)
        var policy = AIUsageRetentionPolicy()
        policy.maximumRecordBytes = 512
        let store = AIUsageMetadataStore(directory: fixture.directory, policy: policy, clock: { now })
        let oversized = await store.save(id: id, data: Data(repeating: 65, count: 513))
        #expect(!oversized.stored && oversized.report.problems == [.oversizedRecord(id)])
        let wrongID = await store.save(id: id, data: try fixture.record(UUID(), at: now))
        #expect(!wrongID.stored && wrongID.report.problems == [.malformedRecord(id)])
        let old = await store.save(id: id, data: try fixture.record(id, at: now.addingTimeInterval(-90 * 86_400)))
        #expect(!old.stored && old.report.problems == [.expiredIncomingRecord(id)])
        #expect(try Data(contentsOf: fixture.file(id)) == original)
    }

    @Test func startupDailyAndAfterSaveMaintenanceStopWithoutDisablingShutdownReceipts() async throws {
        let fixture = try UsageRetentionFixture()
        defer { fixture.remove() }
        let initial = Date(timeIntervalSinceReferenceDate: 20_000_000), expired = UUID(), later = UUID()
        try fixture.put(expired, at: initial.addingTimeInterval(-11))
        try fixture.put(later, at: initial)
        let clock = UsageRetentionClock(initial), reports = UsageRetentionReports()
        var policy = AIUsageRetentionPolicy()
        policy.retentionInterval = 10
        let store = AIUsageMetadataStore(directory: fixture.directory, policy: policy, clock: { clock.get() },
            dailyInterval: .milliseconds(15), reportHandler: { reports.append($0) })
        let startup = await store.start()
        #expect(startup.trigger == .startup && startup.removedIDs == [expired])
        clock.set(initial.addingTimeInterval(11))
        try await usageRetentionEventually { reports.values().contains { $0.trigger == .daily && $0.removedIDs == [later] } }
        await store.stop()
        let stoppedCount = reports.values().count
        try await Task.sleep(for: .milliseconds(60))
        #expect(reports.values().count == stoppedCount)
        let shutdownID = UUID()
        let result = await store.save(id: shutdownID, data: try fixture.record(shutdownID, at: clock.get()))
        #expect(result.stored && result.report.trigger == .afterSave)
        #expect(reports.values().last?.remainingIDs == [shutdownID])
    }
}

private enum UsageRetentionTestError: Error { case syntheticDenied, timeout }

private struct UsageRetentionFixture {
    let base: URL
    let directory: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Synthetic-Usage-" + UUID().uuidString)
        directory = base.appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    func record(_ id: UUID, at date: Date, padding: Int = 0) throws -> Data {
        struct Synthetic: Encodable { let runID: UUID; let recordedAt: Date; let unknown: Bool; let padding: String }
        return try JSONEncoder().encode(Synthetic(runID: id, recordedAt: date, unknown: true, padding: String(repeating: "x", count: padding)))
    }
    @discardableResult func put(_ id: UUID, at date: Date, padding: Int = 0) throws -> Data {
        let data = try record(id, at: date, padding: padding)
        try data.write(to: file(id))
        return data
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

private final class UsageRetentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func get() -> Date { lock.withLock { value } }
    func set(_ next: Date) { lock.withLock { value = next } }
}

private final class UsageRetentionReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [AIUsageMaintenanceReport] = []
    func append(_ value: AIUsageMaintenanceReport) { lock.withLock { reports.append(value) } }
    func values() -> [AIUsageMaintenanceReport] { lock.withLock { reports } }
}

private func usageRetentionEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw UsageRetentionTestError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}
