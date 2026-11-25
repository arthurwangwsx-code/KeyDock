import Darwin
import Foundation
import Testing
@testable import ExecutionCore

private final class RunStoreTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
private final class RunStoreTestFault: @unchecked Sendable {
    private let lock = NSLock()
    private var point: InvocationPersistencePoint?
    func arm(_ value: InvocationPersistencePoint?) { lock.withLock { point = value } }
    func code(_ value: InvocationPersistencePoint) -> Int32? { lock.withLock { point == value ? EIO : nil } }
}
private struct RunStoreFixture: Sendable {
    let directory: URL
    let clock = RunStoreTestClock()
    let fault = RunStoreTestFault()
    let definition = RunDefinitionReference(kind: .savedCommand, definitionID: UUID(), definitionVersion: 1, fingerprint: String(repeating: "a", count: 64))
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Synthetic-RunStore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var file: URL { directory.appendingPathComponent("invocations.json") }
    func store(retention: InvocationRetentionPolicy = .init()) throws -> InvocationStore {
        try .init(directory: directory, retention: retention, clock: { clock.now() }, persistenceFault: { fault.code($0) })
    }
    func terminal(_ store: InvocationStore, id: UUID = UUID()) async throws -> UUID {
        let begun = try await store.begin(id: id, name: "Synthetic saved task", runDefinition: definition)
        try await store.finish(id: id, result: .init(state: .succeeded, exitCode: 0), expectedRunStamp: begun.runStamp)
        await store.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
        return id
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func seed(_ receipts: [InvocationReceipt], version: Int = 2) throws -> Data {
        struct Envelope: Encodable { let version: Int; let receipts: [InvocationReceipt] }
        let data = try JSONEncoder().encode(Envelope(version: version, receipts: receipts)); try data.write(to: file); return data
    }
}

@Suite(.serialized) struct RunStoreTests {
    @Test func materialOwnerIsReadOnlyForActiveAndRevisedRecordsAndChangesAfterRebirth() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), id = UUID(), legacy = UUID()
        try await store.begin(id: legacy, name: "Synthetic untyped")
        #expect(try await store.materialOwner(legacy) == nil)
        let begun = try await store.begin(id: id, name: "Synthetic typed", runDefinition: f.definition)
        let owner = try #require(try await store.materialOwner(id))
        #expect(owner.invocationID == id && owner.recordIdentity == begun.receipt.runAttempt?.recordIdentity && owner.kind == .savedCommand)
        await #expect(throws: InvocationStoreError.activeRecovery) { try await store.inspectRecovery(id) }
        try await store.finish(id: id, result: .init(state: .succeeded), expectedRunStamp: begun.runStamp)
        await store.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
        let check = try await store.inspectRecovery(id), child = UUID()
        let next = try await store.begin(id: child, name: "Synthetic attempt", runDefinition: f.definition, recovering: check)
        #expect(try await store.materialOwner(id) == owner)
        try await store.finish(id: child, result: .init(state: .succeeded), expectedRunStamp: next.runStamp)
        await store.releaseProtection(for: child, expectedRunStamp: next.runStamp)
        _ = await store.clearFinished(onlyIDs: [id, child])
        #expect(try await store.materialOwner(id) == nil)
        let reborn = try await store.begin(id: id, name: "Synthetic rebirth", runDefinition: f.definition)
        let newOwner = try #require(try await store.materialOwner(id))
        #expect(newOwner.recordIdentity == reborn.receipt.runAttempt?.recordIdentity && newOwner != owner)
    }

    @Test func legacyRecordsStayReadOnlyAndTypedRecordsPersistWithoutPayload() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), legacy = UUID()
        try await store.begin(id: legacy, name: "Synthetic legacy")
        try await store.finish(id: legacy, result: .init(state: .succeeded)); await store.releaseProtection(for: legacy)
        await #expect(throws: InvocationStoreError.recoveryUnavailable) { try await store.inspectRecovery(legacy) }
        let id = try await f.terminal(store), check = try await store.inspectRecovery(id)
        #expect(check.receipt.runAttempt?.logicalRunID == id && check.receipt.runAttempt?.revision == 1)
        let bytes = try Data(contentsOf: f.file), object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        let rows = try #require(object["receipts"] as? [[String: Any]])
        let metadata = try #require(rows.first { $0["runAttempt"] != nil }?["runAttempt"] as? [String: Any])
        #expect(Set(metadata.keys) == ["schemaVersion", "recordIdentity", "logicalRunID", "definition", "revision"])
        let reference = try #require(metadata["definition"] as? [String: Any])
        #expect(Set(reference.keys) == ["kind", "definitionID", "definitionVersion", "fingerprint"])
        #expect(try JSONSerialization.data(withJSONObject: metadata).count < 1_024)
        let reopened = try f.store(), snapshot = try await reopened.runStoreSnapshot()
        #expect(snapshot.logicalRuns.count == 1 && snapshot.legacyReceipts.map(\.id) == [legacy])
        #expect(snapshot.logicalRuns.first?.attempts.first?.runAttempt == check.receipt.runAttempt)
        await #expect(throws: InvocationStoreError.foreignRecovery) {
            try await reopened.begin(id: UUID(), name: "Synthetic rejected old actor", runDefinition: f.definition, recovering: check)
        }
    }

    @Test func sameCheckCommitsExactlyOneNewIntentAndPreservesOldOutcome() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), source = try await f.terminal(store), check = try await store.inspectRecovery(source)
        let ids = [UUID(), UUID()]
        let errors = await withTaskGroup(of: InvocationStoreError?.self, returning: [InvocationStoreError?].self) { group in
            for id in ids { group.addTask {
                do { try await store.begin(id: id, name: "Synthetic new attempt", runDefinition: f.definition, recovering: check); return nil }
                catch { return error as? InvocationStoreError ?? .invalidMetadata }
            } }
            var values: [InvocationStoreError?] = []; for await value in group { values.append(value) }; return values
        }
        #expect(errors.filter { $0 == nil }.count == 1 && errors.compactMap { $0 } == [.staleRecovery])
        let rows = await store.list(), old = try #require(rows.first { $0.id == source }), new = try #require(rows.first { $0.id != source })
        #expect(rows.count == 2 && old.runAttempt?.revision == 2)
        #expect(old.state == check.receipt.state && old.finishedAt == check.receipt.finishedAt && old.exitCode == check.receipt.exitCode && old.message == check.receipt.message)
        #expect(new.runAttempt?.recoveryOf == source && new.runAttempt?.logicalRunID == source && new.state == .running)
    }

    @Test func terminalStillDrainingAndOtherLiveAttemptPreventRecovery() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), source = UUID()
        let sourceBegin = try await store.begin(id: source, name: "Synthetic source", runDefinition: f.definition)
        await #expect(throws: InvocationStoreError.activeRecovery) { try await store.inspectRecovery(source) }
        try await store.finish(id: source, result: .init(state: .succeeded), expectedRunStamp: sourceBegin.runStamp)
        await #expect(throws: InvocationStoreError.activeRecovery) { try await store.inspectRecovery(source) }
        await store.releaseProtection(for: source, expectedRunStamp: sourceBegin.runStamp)
        let check = try await store.inspectRecovery(source), child = UUID()
        let childBegin = try await store.begin(id: child, name: "Synthetic child", runDefinition: f.definition, recovering: check)
        try await store.finish(id: child, result: .init(state: .succeeded), expectedRunStamp: childBegin.runStamp)
        await #expect(throws: InvocationStoreError.activeRecovery) { try await store.inspectRecovery(source) }
        await store.releaseProtection(for: child, expectedRunStamp: childBegin.runStamp)
        let fresh = try await store.inspectRecovery(source)
        #expect(fresh.receipt.runAttempt?.revision == 2)
        #expect(try await store.runStoreSnapshot().logicalRuns.first?.hasLiveAttempts == false)
    }

    @Test func clearSameIDRecreationAndForeignStoreRejectOldChecks() async throws {
        let f = try RunStoreFixture(), other = try RunStoreFixture(); defer { f.remove(); other.remove() }
        let store = try f.store(), source = try await f.terminal(store), check = try await store.inspectRecovery(source)
        #expect(await store.clearFinished().removedIDs == [source])
        _ = try await f.terminal(store, id: source)
        await #expect(throws: InvocationStoreError.staleRecovery) {
            try await store.begin(id: UUID(), name: "Synthetic old source", runDefinition: f.definition, recovering: check)
        }
        let foreign = try other.store()
        await #expect(throws: InvocationStoreError.foreignRecovery) {
            try await foreign.begin(id: UUID(), name: "Synthetic foreign source", runDefinition: f.definition, recovering: check)
        }
    }

    @Test func unrelatedWritesDoNotInvalidateAStableSource() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), source = try await f.terminal(store), check = try await store.inspectRecovery(source)
        let unrelated = UUID(), child = UUID()
        try await store.begin(id: unrelated, name: "Synthetic unrelated")
        try await store.finish(id: unrelated, result: .init(state: .succeeded)); await store.releaseProtection(for: unrelated)
        try await store.begin(id: child, name: "Synthetic new attempt", runDefinition: f.definition, recovering: check)
        #expect(await store.list().first { $0.id == child }?.runAttempt?.recoveryOf == source)
    }

    @Test func oldWorkerStampCannotFinishAbandonOrReleaseARecreatedID() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), id = UUID()
        let old = try await store.begin(id: id, name: "Synthetic old birth", runDefinition: f.definition)
        let oldStamp = try #require(old.runStamp)
        try await store.finish(id: id, result: .init(state: .succeeded), expectedRunStamp: oldStamp)
        await store.releaseProtection(for: id, expectedRunStamp: oldStamp)
        #expect(await store.clearFinished().removedIDs == [id])
        let new = try await store.begin(id: id, name: "Synthetic new birth", runDefinition: f.definition)
        let newStamp = try #require(new.runStamp)
        #expect(oldStamp.recordIdentity != newStamp.recordIdentity && oldStamp.revision == newStamp.revision)
        await #expect(throws: InvocationStoreError.staleRecovery) {
            try await store.finish(id: id, result: .init(state: .failed), expectedRunStamp: oldStamp)
        }
        await store.abandonUndispatched(id, expectedRunStamp: oldStamp)
        await store.releaseProtection(for: id, expectedRunStamp: oldStamp)
        #expect(await store.list().first?.state == .running)
        try await store.finish(id: id, result: .init(state: .succeeded), expectedRunStamp: newStamp)
        await #expect(throws: InvocationStoreError.activeRecovery) { try await store.inspectRecovery(id) }
        await store.releaseProtection(for: id, expectedRunStamp: newStamp)
        _ = try await store.inspectRecovery(id)
        let reopened = try f.store()
        await #expect(throws: InvocationStoreError.foreignRecovery) {
            try await reopened.finish(id: id, result: .init(state: .failed), expectedRunStamp: newStamp)
        }
    }

    @Test func referencedMissingIDsCannotBeReboundToNewOrLegacyRecords() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), root = try await f.terminal(store), check = try await store.inspectRecovery(root), child = UUID()
        let begun = try await store.begin(id: child, name: "Synthetic surviving child", runDefinition: f.definition, recovering: check)
        try await store.finish(id: child, result: .init(state: .succeeded), expectedRunStamp: begun.runStamp)
        await store.releaseProtection(for: child, expectedRunStamp: begun.runStamp)
        #expect(await store.clearFinished(onlyIDs: [root]).removedIDs == [root])
        let before = try Data(contentsOf: f.file)
        await #expect(throws: InvocationStoreError.duplicateInvocation) { try await store.begin(id: root, name: "Synthetic legacy rebinding") }
        let other = RunDefinitionReference(kind: .workflow, definitionID: UUID(), fingerprint: String(repeating: "b", count: 64))
        await #expect(throws: InvocationStoreError.duplicateInvocation) { try await store.begin(id: root, name: "Synthetic new root", runDefinition: other) }
        #expect(try Data(contentsOf: f.file) == before)
        let reopened = try f.store(), snapshot = try await reopened.runStoreSnapshot()
        #expect(snapshot.logicalRuns.first?.hasMissingAncestors == true && snapshot.logicalRuns.first?.attempts.map(\.id) == [child])
    }

    @Test func lateLegacyCallsCannotMutateOrReleaseARecreatedTypedAttempt() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), id = UUID()
        try await store.begin(id: id, name: "Synthetic legacy birth")
        try await store.finish(id: id, result: .init(state: .succeeded)); await store.releaseProtection(for: id)
        #expect(await store.clearFinished().removedIDs == [id])
        let begun = try await store.begin(id: id, name: "Synthetic typed birth", runDefinition: f.definition)
        await #expect(throws: InvocationStoreError.staleRecovery) { try await store.finish(id: id, result: .init(state: .failed)) }
        await store.abandonUndispatched(id); await store.releaseProtection(for: id)
        #expect(await store.list().first?.state == .running)
        try await store.finish(id: id, result: .init(state: .succeeded), expectedRunStamp: begun.runStamp)
        #expect(await store.clearFinished().removedIDs.isEmpty)
        await store.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
        #expect(await store.clearFinished().removedIDs == [id])
    }

    @Test func preRenameFailureKeepsSourceRevisionAndCanBeExplicitlyRetried() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), source = try await f.terminal(store), check = try await store.inspectRecovery(source)
        let before = try Data(contentsOf: f.file), failed = UUID()
        f.fault.arm(.beforeRename)
        await #expect(throws: InvocationStoreError.io(EIO)) {
            try await store.begin(id: failed, name: "Synthetic failed intent", runDefinition: f.definition, recovering: check)
        }
        #expect(try Data(contentsOf: f.file) == before)
        #expect(await store.list().map(\.id) == [source])
        f.fault.arm(nil)
        try await store.begin(id: UUID(), name: "Synthetic explicit retry", runDefinition: f.definition, recovering: check)
        #expect(await store.list().first { $0.id == source }?.runAttempt?.revision == 2)
    }

    @Test func postRenameFailureNeverIssuesChecksOrFalselyConfirmsFinish() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), source = try await f.terminal(store), check = try await store.inspectRecovery(source), child = UUID()
        f.fault.arm(.afterRename)
        var rejectedStamp: RunAttemptStamp?
        do {
            try await store.begin(id: child, name: "Synthetic uncertain intent", runDefinition: f.definition, recovering: check)
            Issue.record("Uncertain begin must not return a successful admission")
        } catch let failure as InvocationBeginFailure {
            #expect(failure.cause == .durabilityUncertain(EIO)); rejectedStamp = failure.undispatchedStamp
        }
        let stamp = try #require(rejectedStamp)
        #expect(stamp.invocationID == child)
        #expect(await store.list().count == 2)
        await #expect(throws: InvocationStoreError.recoveryPersistenceUncertain) { try await store.inspectRecovery(source) }
        await #expect(throws: InvocationStoreError.recoveryPersistenceUncertain) { try await store.runStoreSnapshot() }
        await #expect(throws: InvocationStoreError.recoveryPersistenceUncertain) {
            try await store.finish(id: child, result: .init(state: .succeeded), expectedRunStamp: stamp)
        }
        await store.abandonUndispatched(child, expectedRunStamp: stamp)
        f.fault.arm(nil)
        #expect(await store.maintain().failure == nil)
        await #expect(throws: InvocationStoreError.staleRecovery) {
            try await store.begin(id: UUID(), name: "Synthetic consumed check", runDefinition: f.definition, recovering: check)
        }
        #expect(await store.list().first { $0.id == child }?.state == .cancelled)
        _ = try await store.inspectRecovery(source)
    }

    @Test func failedFinishSyncStaysUncertainUntilMaintenanceConfirmsIt() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(), id = UUID()
        let begun = try await store.begin(id: id, name: "Synthetic finish uncertainty", runDefinition: f.definition)
        let stamp = try #require(begun.runStamp)
        f.fault.arm(.afterRename)
        await #expect(throws: InvocationStoreError.durabilityUncertain(EIO)) {
            try await store.finish(id: id, result: .init(state: .succeeded, exitCode: 0), expectedRunStamp: stamp)
        }
        await #expect(throws: InvocationStoreError.recoveryPersistenceUncertain) {
            try await store.finish(id: id, result: .init(state: .failed, exitCode: 1), expectedRunStamp: stamp)
        }
        #expect(await store.list().first?.state == .succeeded)
        await #expect(throws: InvocationStoreError.recoveryPersistenceUncertain) { try await store.materialOwners() }
        f.fault.arm(nil)
        #expect(await store.maintain().failure == nil)
        await store.releaseProtection(for: id, expectedRunStamp: stamp)
        #expect(try await store.inspectRecovery(id).receipt.exitCode == 0)
        #expect(try await store.materialOwners().first?.recordIdentity == begun.receipt.runAttempt?.recordIdentity)
    }

    @Test func onlyDirectRecoverySourceIsProtectedAndOldAncestorsExpire() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let store = try f.store(retention: .init(maxFinishedAge: 10, maxFinishedCount: 1)), root = try await f.terminal(store)
        let first = UUID(), firstCheck = try await store.inspectRecovery(root)
        let firstBegin = try await store.begin(id: first, name: "Synthetic first", runDefinition: f.definition, recovering: firstCheck)
        try await store.finish(id: first, result: .init(state: .succeeded), expectedRunStamp: firstBegin.runStamp); await store.releaseProtection(for: first, expectedRunStamp: firstBegin.runStamp)
        let second = UUID(), secondCheck = try await store.inspectRecovery(first)
        let secondBegin = try await store.begin(id: second, name: "Synthetic second", runDefinition: f.definition, recovering: secondCheck)
        f.clock.advance(20)
        let report = await store.maintain()
        #expect(report.removedIDs == [root] && report.protectedIDs == [first, second])
        #expect(try await store.runStoreSnapshot().logicalRuns.first?.hasMissingAncestors == true)
        try await store.finish(id: second, result: .init(state: .succeeded), expectedRunStamp: secondBegin.runStamp); await store.releaseProtection(for: second, expectedRunStamp: secondBegin.runStamp)
        #expect(await store.maintain().removedIDs == [first])
        #expect(await store.list().map(\.id) == [second])
    }

    @Test func coldUnknownAttemptProtectsItsDirectSourceUntilAcknowledged() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let retention = InvocationRetentionPolicy(maxFinishedAge: 10, maxFinishedCount: 2)
        let first = try f.store(retention: retention), source = try await f.terminal(first), check = try await first.inspectRecovery(source), child = UUID()
        try await first.begin(id: child, name: "Synthetic cold interrupted", runDefinition: f.definition, recovering: check)
        f.clock.advance(20)
        let cold = try f.store(retention: retention)
        #expect(Set(await cold.list().map(\.id)) == [source, child])
        #expect(await cold.list().first { $0.id == child }?.state == .interrupted)
        #expect(await cold.maintain().removedIDs.isEmpty)
        await cold.acknowledgeRecovery()
        #expect(await cold.maintain().removedIDs == [source])
        #expect(try await cold.runStoreSnapshot().logicalRuns.first?.hasMissingAncestors == true)
    }

    @Test func capacityRejectionDoesNotConsumeTheSourceOrAlterTheFile() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let original = try f.store(), source = try await f.terminal(original)
        let count = try Data(contentsOf: f.file).count
        let store = try f.store(retention: .init(maxFileBytes: count + 4_096))
        let check = try await store.inspectRecovery(source), before = try Data(contentsOf: f.file)
        await #expect(throws: InvocationStoreError.capacityExceeded) {
            try await store.begin(id: UUID(), name: "Synthetic capacity rejected", runDefinition: f.definition, recovering: check)
        }
        #expect(try Data(contentsOf: f.file) == before)
        #expect(try await store.inspectRecovery(source).receipt.runAttempt?.revision == check.receipt.runAttempt?.revision)
    }

    @Test func malformedGraphsAndUnknownSchemaPreserveOriginalBytes() throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let a = UUID(), b = UUID(), group = UUID()
        let cycle = [InvocationReceipt(id: a, name: "Synthetic A", state: .succeeded, startedAt: f.clock.now(), runAttempt: .init(logicalRunID: group, recoveryOf: b, definition: f.definition)),
                     InvocationReceipt(id: b, name: "Synthetic B", state: .succeeded, startedAt: f.clock.now(), runAttempt: .init(logicalRunID: group, recoveryOf: a, definition: f.definition))]
        let cases = [cycle, [.init(id: a, name: "Synthetic self", state: .succeeded, startedAt: f.clock.now(), runAttempt: .init(logicalRunID: group, recoveryOf: a, definition: f.definition))],
                     [.init(id: a, name: "Synthetic future", state: .succeeded, startedAt: f.clock.now(), runAttempt: .init(logicalRunID: a, definition: f.definition, schemaVersion: 2))]]
        for records in cases {
            let bytes = try f.seed(records)
            #expect(throws: InvocationStoreError.invalidMetadata) { try f.store() }
            #expect(try Data(contentsOf: f.file) == bytes)
        }
        let valid = InvocationReceipt(id: a, name: "Synthetic typed", state: .succeeded, startedAt: f.clock.now(), runAttempt: .init(logicalRunID: a, definition: f.definition))
        let bytes = try f.seed([valid], version: 1)
        #expect(throws: InvocationStoreError.invalidMetadata) { try f.store() }
        #expect(try Data(contentsOf: f.file) == bytes)
    }

    @Test func missingAncestorIsAGapAndRevisionDoesNotWrap() async throws {
        let f = try RunStoreFixture(); defer { f.remove() }
        let id = UUID(), absent = UUID()
        _ = try f.seed([.init(id: id, name: "Synthetic missing ancestor", state: .succeeded, startedAt: f.clock.now(), runAttempt: .init(logicalRunID: absent, recoveryOf: absent, definition: f.definition, revision: UInt64.max))])
        let store = try f.store()
        #expect(try await store.runStoreSnapshot().logicalRuns.first?.hasMissingAncestors == true)
        await #expect(throws: InvocationStoreError.revisionExhausted) { try await store.inspectRecovery(id) }
        #expect(await store.list().first?.runAttempt?.revision == UInt64.max)
    }
}
