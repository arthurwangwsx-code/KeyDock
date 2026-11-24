import Foundation
import Testing
@testable import AutomationCore

private enum ScheduleInjectedError: Error, Equatable { case write }
private final class ScheduleMemoryDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var shouldFail = false
    func fail(_ value: Bool) { lock.withLock { shouldFail = value } }
    func data() -> Data? { lock.withLock { bytes } }
    func inject(_ value: Data) { lock.withLock { bytes = value } }
    var persistence: SchedulePersistence {
        SchedulePersistence(load: { self.lock.withLock { self.bytes } }, save: { value in
            try self.lock.withLock {
                if self.shouldFail { throw ScheduleInjectedError.write }
                self.bytes = value
            }
        })
    }
}
@Suite(.serialized) struct ScheduleLedgerTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000.12345)
    private func definition(id: UUID = UUID(), workflowID: UUID, enabled: Bool = true, revision: Int = 1) -> ScheduleDefinition {
        ScheduleDefinition(id: id, name: "Synthetic schedule", workflowID: workflowID, enabled: enabled, trigger: .interval(seconds: 10), revision: revision)
    }
    @Test func scheduleApprovalDoesNotAuthorizeAnotherScheduleForTheSameWorkflow() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID(), ledger = try ScheduleLedger(persistence:disk.persistence,now:start)
        let approved = definition(workflowID:workflow), other = definition(workflowID:workflow)
        try await ledger.upsert(approved,now:start); try await ledger.upsert(other,now:start)
        let claims = try await ledger.claimDue(now:start.addingTimeInterval(20),availableWorkflowIDs:[workflow],unattendedWorkflowIDs:[workflow],authorizedScheduleIDs:[approved.id])
        #expect(claims.count == 1 && claims.first?.scheduleID == approved.id)
        #expect(await ledger.snapshots().first(where:{$0.id == other.id})?.activeAttempt == nil)
    }
    @Test func overduePeriodsCoalesceAndKnownFailureNeverRetriesTheSamePoint() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        let schedule = definition(workflowID: workflow)
        try await ledger.upsert(schedule, now: start)
        let due = start.addingTimeInterval(100)
        let claims = try await ledger.claimDue(now: due, availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow])
        let claim = try #require(claims.first)
        #expect(claims.count == 1 && claim.scheduledFireAt == start.addingTimeInterval(10))
        #expect(try await ledger.claimDue(now: due, availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
        #expect(try await ledger.complete(attemptID: claim.id, outcome: .failed, now: start.addingTimeInterval(103)))
        let snapshot = try #require(await ledger.snapshots().first)
        #expect(snapshot.nextFireAt == start.addingTimeInterval(110) && !snapshot.reviewRequired)
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(109), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
        let next = try #require(try await ledger.claimDue(now: start.addingTimeInterval(110), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        #expect(next.id != claim.id && next.idempotencyKey != claim.idempotencyKey)
        #expect(!(try await ledger.complete(attemptID: claim.id, outcome: .succeeded, now: start.addingTimeInterval(111))))
    }
    @Test func missingOrApprovalRequiringWorkflowIsNotClaimed() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        try await ledger.upsert(definition(workflowID: workflow), now: start)
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [], unattendedWorkflowIDs: [workflow]).isEmpty)
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: []).isEmpty)
        #expect(await ledger.snapshots().first?.activeAttempt == nil)
    }
    @Test func claimAndCompletionArePublishedOnlyAfterPersistence() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        try await ledger.upsert(definition(workflowID: workflow), now: start)
        let before = disk.data(); disk.fail(true)
        do {
            _ = try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow])
            Issue.record("Expected claim write failure")
        } catch { #expect(error as? ScheduleInjectedError == .write) }
        let activeAfterFailure = await ledger.snapshots().first?.activeAttempt
        #expect(disk.data() == before && activeAfterFailure == nil)
        disk.fail(false)
        let claim = try #require(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        disk.fail(true)
        do { _ = try await ledger.complete(attemptID: claim.id, outcome: .succeeded, now: start.addingTimeInterval(11)); Issue.record("Expected completion write failure") }
        catch { #expect(error as? ScheduleInjectedError == .write) }
        #expect(await ledger.snapshots().first?.activeAttempt?.id == claim.id)
        disk.fail(false)
        #expect(try await ledger.complete(attemptID: claim.id, outcome: .succeeded, now: start.addingTimeInterval(12)))
    }
    @Test func restartMarksOpenClaimUnknownAndRequiresExplicitReview() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let first = try ScheduleLedger(persistence: disk.persistence, now: start)
        let schedule = definition(workflowID: workflow)
        try await first.upsert(schedule, now: start)
        let claim = try #require(try await first.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        let restored = try ScheduleLedger(persistence: disk.persistence, now: start.addingTimeInterval(51))
        let snapshot = try #require(await restored.snapshots().first)
        #expect(snapshot.activeAttempt == nil && snapshot.lastAttempt?.id == claim.id && snapshot.lastAttempt?.outcome == .unknown)
        #expect(snapshot.lastAttempt?.idempotencyKey == claim.idempotencyKey && snapshot.reviewRequired)
        #expect(snapshot.nextFireAt == start.addingTimeInterval(60))
        #expect(try await restored.claimDue(now: start.addingTimeInterval(100), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
        try await restored.acknowledgeUnknown(id: schedule.id, expectedRevision: 1, now: start.addingTimeInterval(100))
        #expect(try await restored.claimDue(now: start.addingTimeInterval(100), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
        let next = try #require(try await restored.claimDue(now: start.addingTimeInterval(110), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        #expect(next.idempotencyKey != claim.idempotencyKey)
    }
    @Test func editingOrDisablingInvalidatesLateCompletion() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        let schedule = definition(workflowID: workflow)
        try await ledger.upsert(schedule, now: start)
        let claim = try #require(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        let mutation = try await ledger.upsert(definition(id: schedule.id, workflowID: workflow, revision: 2), now: start.addingTimeInterval(11))
        #expect(mutation.invalidatedAttemptID == claim.id && mutation.snapshot.reviewRequired)
        #expect(!(try await ledger.complete(attemptID: claim.id, outcome: .succeeded, now: start.addingTimeInterval(12))))
        do { _ = try await ledger.setEnabled(false, id: schedule.id, expectedRevision: 1, now: start.addingTimeInterval(13)); Issue.record("Expected stale revision refusal") }
        catch { #expect(error as? ScheduleError == .revisionConflict) }
        try await ledger.setEnabled(false, id: schedule.id, expectedRevision: 2, now: start.addingTimeInterval(13))
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(100), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
    }
    @Test func failedDisableStillSuspendsCurrentSessionAndRejectsLateResult() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        let schedule = definition(workflowID: workflow)
        try await ledger.upsert(schedule, now: start)
        let claim = try #require(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        disk.fail(true)
        do { _ = try await ledger.setEnabled(false, id: schedule.id, expectedRevision: 1, now: start.addingTimeInterval(11)); Issue.record("Expected disable persistence failure") }
        catch { #expect(error as? ScheduleInjectedError == .write) }
        #expect(await ledger.isSuspendedForSession(id: schedule.id))
        #expect(!(try await ledger.complete(attemptID: claim.id, outcome: .succeeded, now: start.addingTimeInterval(12))))
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(100), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
        disk.fail(false)
        let mutation = try await ledger.setEnabled(false, id: schedule.id, expectedRevision: 1, now: start.addingTimeInterval(101))
        #expect(!mutation.snapshot.definition.enabled && mutation.snapshot.reviewRequired)
    }
    @Test func reenablingAfterFailedPauseRequiresANewGenerationAndReview() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        let schedule = definition(workflowID: workflow)
        try await ledger.upsert(schedule, now: start)
        _ = try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow])
        disk.fail(true)
        do { _ = try await ledger.setEnabled(false, id: schedule.id, expectedRevision: 1, now: start.addingTimeInterval(11)); Issue.record("Expected pause write failure") }
        catch { #expect(error as? ScheduleInjectedError == .write) }
        disk.fail(false)
        let resumed = try await ledger.setEnabled(true, id: schedule.id, expectedRevision: 1, now: start.addingTimeInterval(12))
        #expect(resumed.snapshot.definition.revision == 2 && resumed.snapshot.reviewRequired)
        #expect(!(await ledger.isSuspendedForSession(id: schedule.id)))
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(100), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
    }
    @Test func unknownCompletionNeverAutomaticallyRunsAnotherPeriod() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        try await ledger.upsert(definition(workflowID: workflow), now: start)
        let claim = try #require(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        #expect(try await ledger.complete(attemptID: claim.id, outcome: .unknown, now: start.addingTimeInterval(11)))
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(10_000), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).isEmpty)
    }
    @Test func privateStoreRecoveryAndCorruptMetadataFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-schedule-proposal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let schedule = definition(workflowID: UUID())
        let ledger = try ScheduleLedger(directory: root, now: start)
        try await ledger.upsert(schedule, now: start)
        let active = try #require(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [schedule.workflowID], unattendedWorkflowIDs: [schedule.workflowID]).first)
        let restored = try ScheduleLedger(directory: root, now: start.addingTimeInterval(11))
        #expect(await restored.snapshots().first?.lastAttempt?.idempotencyKey == active.idempotencyKey)
        #expect(await restored.snapshots().first?.reviewRequired == true)
        let file = root.appendingPathComponent("scheduled-workflows.json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data("invalid metadata".utf8).write(to: file)
        #expect(throws: ScheduleError.corruptStorage) { _ = try ScheduleLedger(directory: root, now: start) }
    }
    @Test func duplicateAttemptIdentityAcrossSchedulesFailsClosed() async throws {
        let disk = ScheduleMemoryDisk(), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        try await ledger.upsert(definition(workflowID: workflow), now: start)
        try await ledger.upsert(definition(workflowID: workflow), now: start)
        #expect(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).count == 2)
        let originalBytes = try #require(disk.data())
        var envelope = try #require(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
        var rows = try #require(envelope["records"] as? [[String: Any]])
        let first = try #require(rows[0]["activeAttempt"] as? [String: Any])
        var second = try #require(rows[1]["activeAttempt"] as? [String: Any])
        second["id"] = first["id"]; rows[1]["activeAttempt"] = second
        envelope["records"] = rows
        let corrupted = try JSONSerialization.data(withJSONObject: envelope)
        disk.inject(corrupted)
        #expect(throws: ScheduleError.corruptStorage) { _ = try ScheduleLedger(persistence: disk.persistence, now: start.addingTimeInterval(11)) }
        #expect(disk.data() == corrupted)
    }
    @Test func explicitTimeZoneHandlesDSTAndRejectsInvalidTimes() throws {
        let iso = ISO8601DateFormatter()
        let spring = try #require(iso.date(from: "2026-03-08T05:00:00Z"))
        let afterGap = try ScheduleCalendar.nextFire(for: .daily(hour: 2, minute: 30, timeZoneID: "America/New_York"), after: spring)
        #expect(iso.string(from: afterGap) == "2026-03-08T07:00:00Z")
        let fall = try #require(iso.date(from: "2026-11-01T05:31:00Z"))
        let nextDay = try ScheduleCalendar.nextFire(for: .daily(hour: 1, minute: 30, timeZoneID: "America/New_York"), after: fall)
        #expect(iso.string(from: nextDay) == "2026-11-02T06:30:00Z")
        #expect(throws: ScheduleError.invalidTrigger) { try ScheduleCalendar.nextFire(for: .interval(seconds: .nan), after: start) }
        #expect(throws: ScheduleError.invalidTrigger) { try ScheduleCalendar.nextFire(for: .daily(hour: 24, minute: 0, timeZoneID: "UTC"), after: start) }
        #expect(throws: ScheduleError.invalidClock) { try ScheduleCalendar.nextFire(for: .interval(seconds: 10), after: Date(timeIntervalSinceReferenceDate: 1e100)) }
    }
}
