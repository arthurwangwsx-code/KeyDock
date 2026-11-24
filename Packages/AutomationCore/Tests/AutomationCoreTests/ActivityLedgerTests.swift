import Foundation
import Testing
@testable import AutomationCore

private enum InjectedActivityError: Error, Equatable { case write }
private final class ActivityMemoryDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var shouldFail = false
    func fail(_ value: Bool) { lock.withLock { shouldFail = value } }
    func data() -> Data? { lock.withLock { bytes } }
    var persistence: ActivityPersistence {
        ActivityPersistence(load: { self.lock.withLock { self.bytes } }, save: { data in
            try self.lock.withLock {
                if self.shouldFail { throw InjectedActivityError.write }
                self.bytes = data
            }
        })
    }
}
@Suite(.serialized) struct ActivityLedgerTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    @Test func optInPauseAndNoBackfill() async throws {
        let disk = ActivityMemoryDisk()
        let ledger = try ActivityLedger(persistence: disk.persistence, now: start)
        let before = ActivityEvent(commandID: "command.synthetic", category: .command, outcome: .succeeded, duration: 1, date: start)
        #expect(try await !ledger.record(before, now: start)); #expect(disk.data() == nil)
        try await ledger.setEnabled(true, now: start.addingTimeInterval(10))
        #expect(try await !ledger.record(before, now: start.addingTimeInterval(10)))
        let current = ActivityEvent(commandID: "command.synthetic", category: .command, outcome: .succeeded, duration: 1, date: start.addingTimeInterval(11))
        #expect(try await ledger.record(current, now: start.addingTimeInterval(11)))
        try await ledger.setEnabled(false, now: start.addingTimeInterval(12))
        let paused = ActivityEvent(commandID: "command.synthetic", category: .command, outcome: .failed, duration: 2, date: start.addingTimeInterval(13))
        #expect(try await !ledger.record(paused, now: start.addingTimeInterval(13)))
        try await ledger.setEnabled(true, now: start.addingTimeInterval(14))
        #expect(try await !ledger.record(paused, now: start.addingTimeInterval(14)))
        let report = try await ledger.report(from: start, to: start.addingTimeInterval(20), now: start.addingTimeInterval(20))
        #expect(report.totalCount == 1 && !report.coverageIsComplete)
    }
    @Test func clearRejectsOldQueuedEventsButAcceptsNewCompletions() async throws {
        let disk = ActivityMemoryDisk()
        let ledger = try ActivityLedger(persistence:disk.persistence,enabled:true,now:start)
        let old = ActivityEvent(commandID:"command.old",category:.command,outcome:.succeeded,duration:1,date:start.addingTimeInterval(1))
        try await ledger.clear(now:start.addingTimeInterval(2))
        #expect(try await !ledger.record(old,now:start.addingTimeInterval(3)))
        let new = ActivityEvent(commandID:"command.new",category:.command,outcome:.succeeded,duration:1,date:start.addingTimeInterval(3))
        #expect(try await ledger.record(new,now:start.addingTimeInterval(3)))
    }
    @Test func rehydratesMetadataDeduplicatesAndExportsOnlyAggregates() async throws {
        let disk = ActivityMemoryDisk()
        let ledger = try ActivityLedger(persistence: disk.persistence, enabled: true, now: start)
        let outcomes: [ActivityOutcome] = [.succeeded, .failed, .succeeded, .cancelled, .unknown]
        var first: ActivityEvent?
        for (index, outcome) in outcomes.enumerated() {
            let event = ActivityEvent(commandID: index == 3 ? "utility.synthetic" : "command.synthetic", category: .command,
                                      outcome: outcome, duration: Double(index + 1), date: start.addingTimeInterval(Double(index)))
            if first == nil { first = event }
            #expect(try await ledger.record(event, now: event.date))
        }
        #expect(try await !ledger.record(first!, now: start.addingTimeInterval(5)))
        let restored = try ActivityLedger(persistence: disk.persistence, now: start.addingTimeInterval(5))
        let report = try await restored.report(from: start, to: start.addingTimeInterval(5), now: start.addingTimeInterval(5))
        #expect(!report.trackingEnabledNow && report.totalCount == 5)
        #expect(report.outcomeCounts["unknown"] == 1 && report.successRateAmongKnownCompletions == 2.0 / 3.0)
        #expect(report.totalDuration == 15 && report.averageDuration == 3)
        #expect(report.topCommands.first?.commandID == "command.synthetic" && report.topCommands.first?.count == 4)
        #expect(report.days.count == 1 && report.days.first?.count == 5)
        let exported = try await restored.exportAggregate(from: start, to: start.addingTimeInterval(5), now: start.addingTimeInterval(5))
        let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        #expect(object["events"] == nil && object["totalCount"] as? Int == 5)
        let empty = try await restored.report(from: start.addingTimeInterval(5), to: start.addingTimeInterval(6), now: start.addingTimeInterval(6))
        #expect(empty.totalCount == 0 && empty.successRateAmongKnownCompletions == nil && empty.averageDuration == nil)
    }
    @Test func recordAndClearFailuresDoNotMutateLiveFacts() async throws {
        let disk = ActivityMemoryDisk()
        let ledger = try ActivityLedger(persistence: disk.persistence, enabled: true, now: start)
        try await ledger.record(ActivityEvent(commandID: "command.one", category: .command, outcome: .succeeded, duration: 1, date: start), now: start)
        let before = disk.data()
        disk.fail(true)
        do {
            try await ledger.record(ActivityEvent(commandID: "command.two", category: .command, outcome: .failed, duration: 1, date: start.addingTimeInterval(1)), now: start.addingTimeInterval(1))
            Issue.record("Expected injected write failure")
        } catch { #expect(error as? InjectedActivityError == .write) }
        do { try await ledger.clear(); Issue.record("Expected injected clear failure") }
        catch { #expect(error as? InjectedActivityError == .write) }
        #expect(disk.data() == before)
        disk.fail(false)
        let report = try await ledger.report(from: start, to: start.addingTimeInterval(2), now: start.addingTimeInterval(2))
        #expect(report.totalCount == 1 && report.topCommands.first?.commandID == "command.one")
        try await ledger.clear()
        let after = try await ledger.report(from: start, to: start.addingTimeInterval(2), now: start.addingTimeInterval(2))
        #expect(after.totalCount == 0)
    }
    @Test func invalidMetadataCannotEnterTheLedger() async throws {
        let disk = ActivityMemoryDisk()
        let ledger = try ActivityLedger(persistence: disk.persistence, enabled: true, now: start)
        for event in [ActivityEvent(commandID: "/private/synthetic-body", category: .command, outcome: .succeeded, duration: 1, date: start),
                      ActivityEvent(commandID: "command.synthetic", category: .command, outcome: .succeeded, duration: .nan, date: start)] {
            do { try await ledger.record(event, now: start); Issue.record("Expected metadata admission rejection") }
            catch { #expect(error as? ActivityError == .invalidEvent) }
        }
        #expect(disk.data() == nil)
    }
    @Test func retentionCountAndByteBudgetsPersistTheNewestEvents() async throws {
        let disk = ActivityMemoryDisk()
        let ledger = try ActivityLedger(persistence: disk.persistence, enabled: true, policy: .init(maxEvents: 2, maxBytes: 512), now: start)
        for index in 0..<8 {
            let event = ActivityEvent(commandID: "command." + String(repeating: "x", count: 160) + String(index), category: .command,
                                      outcome: .succeeded, duration: 1, date: start)
            try await ledger.record(event, now: start)
        }
        #expect(try #require(disk.data()).count <= 512)
        let report = try await ledger.report(from: start, to: start.addingTimeInterval(1), now: start)
        #expect(report.totalCount == 1 && report.topCommands.first?.commandID.hasSuffix("7") == true)
        let later = start.addingTimeInterval(31 * 86_400)
        let expired = try await ledger.report(from: start, to: later, now: later)
        #expect(expired.totalCount == 0)
        let restored = try ActivityLedger(persistence: disk.persistence, now: later)
        #expect(try await restored.report(from: start, to: later, now: later).totalCount == 0)
    }
    @Test func privateJSONPersistsWithPrivateModesAndRejectsSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-activity-proposal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ActivityLedger(directory: root, enabled: true, now: start)
        try await ledger.record(ActivityEvent(commandID: "command.synthetic", category: .command, outcome: .succeeded, duration: 1, date: start), now: start)
        try await ledger.record(ActivityEvent(commandID: "command.synthetic", category: .command, outcome: .failed, duration: 2, date: start.addingTimeInterval(1)), now: start.addingTimeInterval(1))
        let file = root.appendingPathComponent("activity-metadata.json")
        #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restored = try ActivityLedger(directory: root, now: start.addingTimeInterval(1))
        #expect(try await restored.report(from: start, to: start.addingTimeInterval(2), now: start.addingTimeInterval(1)).totalCount == 2)
        let sentinel = root.appendingPathComponent("synthetic-sentinel")
        try Data("synthetic sentinel".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
        do { _ = try ActivityLedger(directory: root, now: start); Issue.record("Expected symlink rejection") }
        catch { #expect(error as? ActivityError == .invalidStorage) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "synthetic sentinel")
    }
    @Test func corruptPersistenceFailsClosed() throws {
        let persistence = ActivityPersistence(load: { Data("not valid JSON".utf8) }, save: { _ in Issue.record("Must not overwrite corrupt evidence") })
        #expect(throws: ActivityError.corruptStorage) { _ = try ActivityLedger(persistence: persistence, now: start) }
    }
}
