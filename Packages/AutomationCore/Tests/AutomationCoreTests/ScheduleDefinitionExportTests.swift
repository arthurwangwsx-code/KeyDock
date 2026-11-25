import Foundation
import Testing
@testable import AutomationCore

private final class ExportScheduleDisk: @unchecked Sendable {
    let lock = NSLock()
    private var bytes: Data?
    private var writes = 0
    private var failing = false
    var persistence: SchedulePersistence { .init(load: { self.lock.withLock { self.bytes } }, save: { data in
        try self.lock.withLock {
            if self.failing { throw ScheduleError.invalidStorage }
            self.bytes = data; self.writes += 1
        }
    }) }
    func fail() { lock.withLock { failing = true } }
    func count() -> Int { lock.withLock { writes } }
}
struct ScheduleDefinitionExportTests {
    @Test func definitionSnapshotsExcludeAuthorizationAndRuntimeAndNeverPersistOrClaim() async throws {
        let disk = ExportScheduleDisk(), start = Date(timeIntervalSince1970: 1_700_000_000), workflow = UUID()
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: start)
        let initial = await ledger.definitionSnapshot()
        let definition = ScheduleDefinition(name: "Synthetic", workflowID: workflow, enabled: true, trigger: .interval(seconds: 10), authorizationFingerprint: "SECRET_AUTHORIZATION_SENTINEL")
        try await ledger.upsert(definition, now: start)
        let before = await ledger.snapshots(), snapshot = await ledger.definitionSnapshot(), writes = disk.count()
        #expect(snapshot.generation != initial.generation && snapshot.definitions.count == 1)
        let data = try JSONEncoder().encode(snapshot.definitions)
        #expect(!String(decoding: data, as: UTF8.self).contains("SECRET_AUTHORIZATION_SENTINEL"))
        let item = try #require((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        #expect(Set(item.keys) == ["id", "name", "workflowID", "enabled", "trigger", "revision"])
        #expect(await ledger.snapshots() == before && disk.count() == writes)
        let claim = try #require(try await ledger.claimDue(now: start.addingTimeInterval(10), availableWorkflowIDs: [workflow], unattendedWorkflowIDs: [workflow]).first)
        #expect(await ledger.definitionSnapshot().generation == snapshot.generation)
        _ = try await ledger.complete(attemptID: claim.id, outcome: .unknown, now: start.addingTimeInterval(11))
        _ = try await ledger.acknowledgeUnknown(id: definition.id, expectedRevision: 1, now: start.addingTimeInterval(12))
        #expect(await ledger.definitionSnapshot().generation == snapshot.generation)
        _ = try await ledger.setEnabled(false, id: definition.id, expectedRevision: 1, now: start.addingTimeInterval(13))
        let changed = await ledger.definitionSnapshot()
        #expect(changed.generation != snapshot.generation && changed.definitions.first?.enabled == false)
        _ = try await ledger.remove(id: definition.id, expectedRevision: 2)
        #expect(await ledger.definitionSnapshot().generation != changed.generation)
    }
    @Test func failedDefinitionPersistenceDoesNotPublishANewGeneration() async throws {
        let disk = ExportScheduleDisk(), now = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = try ScheduleLedger(persistence: disk.persistence, now: now)
        let before = await ledger.definitionSnapshot(); disk.fail()
        do { try await ledger.upsert(.init(name: "Synthetic", workflowID: UUID(), trigger: .interval(seconds: 10)), now: now); Issue.record("Expected failure") }
        catch { #expect(error as? ScheduleError == .invalidStorage) }
        let after = await ledger.definitionSnapshot()
        #expect(after.generation == before.generation && after.definitions.isEmpty)
    }
}
