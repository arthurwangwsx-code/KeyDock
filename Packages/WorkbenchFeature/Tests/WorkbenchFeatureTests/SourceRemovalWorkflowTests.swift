import Foundation
import Testing
import Combine
import CommandCore
import AutomationCore
import MacAdapters
@testable import WorkbenchFeature

@MainActor @Suite(.serialized) struct SourceRemovalWorkflowTests {
    @Test func authoritativeDisabledScheduleAndCollectionBlockWithoutSideEffects() async throws {
        try await withSourceRemovalFixture { f, relay in
            let value = try makeRemovalWorkflow(in: f), now = Date()
            let schedule = ScheduleDefinition(name: "Synthetic disabled reference", workflowID: value.id, trigger: .interval(seconds: 60))
            try await f.store.scheduleLedger.upsert(schedule, now: now)
            // UI缓存故意保持空；权威账本仍必须阻止删除。
            #expect(f.store.schedules.isEmpty)
            var next = f.store.configuration
            next.collections = [try .init(name: "Synthetic collection", commandIDs: ["workflow." + value.id.uuidString])]
            #expect(f.store.commitShortcutConfiguration(next))
            let path = f.directory.appendingPathComponent("configuration.json"), original = try Data(contentsOf: path), writes = relay.writes
            let review = try await f.store.reviewSourceRemoval(.workflow(value.id))
            #expect(Set(review.dependencies.map(\.kind)) == [.schedule, .collection])
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Referenced workflow was removed") }
            catch { #expect(error as? SourceRemovalError == .inUse) }
            #expect(try Data(contentsOf: path) == original && relay.writes == writes)
            #expect(!f.store.scheduleBusy && f.store.scheduleMutationOwner == nil)
            await f.assertNoExecution()
        }
    }
    @Test func successfulRemovalCleansExactPreferencesAndKeepsOtherObjects() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = try makeRemovalWorkflow(in: f), other = try makeRemovalWorkflow(in: f, name: "Other synthetic workflow")
            let key = "workflow." + value.id.uuidString, otherKey = "workflow." + other.id.uuidString
            var next = f.store.configuration
            for (offset, id) in [key, otherKey].enumerated() { next.commandShortcuts[id] = .init(keyCode: UInt32(12 + offset), modifiers: 0x1800); next.preferences.aliases[id] = "synthetic alias"; next.preferences.favorites.insert(id); next.preferences.recent[id] = Date() }
            #expect(f.store.commitShortcutConfiguration(next))
            let review = try await f.store.reviewSourceRemoval(.workflow(value.id))
            try await f.store.removeSource(review, isCurrent: { true })
            let saved = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: f.directory.appendingPathComponent("configuration.json")))
            #expect(saved.workflows == [other] && saved.commandShortcuts[key] == nil && saved.preferences.aliases[key] == nil && saved.preferences.recent[key] == nil && !saved.preferences.favorites.contains(key))
            #expect(saved.commandShortcuts[otherKey] != nil && saved.preferences.aliases[otherKey] == "synthetic alias" && saved.preferences.favorites.contains(otherKey))
            #expect(f.store.configurationOperations.isEmpty)
            await f.assertNoExecution()
        }
    }
    @Test(arguments: [SourceRemovalWriteRelay.Failure.before, .after])
    func persistenceFailureRestoresDefinitionFileAndShortcutRegistration(_ mode: SourceRemovalWriteRelay.Failure) async throws {
        try await withSourceRemovalFixture { f, relay in
            let value = try makeRemovalWorkflow(in: f), key = "workflow." + value.id.uuidString
            var next = f.store.configuration; next.commandShortcuts[key] = .init(keyCode: 12, modifiers: 0x1800); next.preferences.aliases[key] = "synthetic"; next.preferences.favorites.insert(key)
            #expect(f.store.commitShortcutConfiguration(next))
            let original = try Data(contentsOf: f.directory.appendingPathComponent("configuration.json"))
            var registrations: [Bool] = []
            f.store.onShortcutConfigurationChanged = { registrations.append($0.commandShortcuts[key] != nil) }
            let review = try await f.store.reviewSourceRemoval(.workflow(value.id)); relay.failure = mode
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Expected persistence failure") }
            catch { if case SourceRemovalError.persistence = error {} else { Issue.record("Unexpected failure: \(error)") } }
            #expect(try Data(contentsOf: f.directory.appendingPathComponent("configuration.json")) == original)
            #expect(f.store.configuration.workflows == [value] && registrations == [false, true])
            #expect(!f.store.scheduleBusy && f.store.scheduleMutationOwner == nil)
        }
    }
    @Test(arguments: ["capture", "confirm"])
    func configurationABAAcrossAwaitRejectsTheOldOperation(_ phase: String) async throws {
        try await withSourceRemovalFixture { f, relay in
            let value = try makeRemovalWorkflow(in: f), gate = SourceRemovalGate(), writes = relay.writes
            defer { Task { await gate.release() } }
            let review = try await f.store.reviewSourceRemoval(.workflow(value.id)), snapshot = await f.store.scheduleLedger.definitionSnapshot()
            let operation = Task {
                if phase == "capture" { _ = try await f.store.reviewSourceRemoval(.workflow(value.id), scheduleReader: { await gate.wait(); return snapshot }) }
                else { try await f.store.removeSource(review, isCurrent: { true }, scheduleReader: { await gate.wait(); return snapshot }) }
            }
            try await f.eventually { await gate.entered }
            let old = f.store.configuration.language; f.store.configuration.language = "en"; f.store.configuration.language = old
            await gate.release()
            do { try await operation.value; Issue.record("Expected ABA rejection") } catch { #expect(error as? SourceRemovalError == .changed) }
            #expect(relay.writes == writes && f.store.configuration.workflows == [value])
        }
    }
    @Test func scheduleDefinitionABASinceReviewRequiresANewReview() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = try makeRemovalWorkflow(in: f), review = try await f.store.reviewSourceRemoval(.workflow(value.id))
            let added = ScheduleDefinition(name: "Synthetic transient", workflowID: value.id, trigger: .interval(seconds: 60))
            try await f.store.scheduleLedger.upsert(added, now: Date())
            _ = try await f.store.scheduleLedger.remove(id: added.id, expectedRevision: 1)
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Expected ledger ABA rejection") }
            catch { #expect(error as? SourceRemovalError == .changed) }
            #expect(f.store.configuration.workflows == [value])
        }
    }
    @Test func sharedGateRejectsConcurrentPlanCreationInBothDirections() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = try makeRemovalWorkflow(in: f), review = try await f.store.reviewSourceRemoval(.workflow(value.id))
            let owner = try #require(f.store.beginScheduleMutation())
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Expected busy gate") }
            catch { #expect(error as? SourceRemovalError == .busy) }
            f.store.finishScheduleMutation(owner)
            let gate = SourceRemovalGate(), snapshot = await f.store.scheduleLedger.definitionSnapshot()
            defer { Task { await gate.release() } }
            let removal = Task { try await f.store.removeSource(review, isCurrent: { true }, scheduleReader: { await gate.wait(); return snapshot }) }
            try await f.eventually { await gate.entered }
            await f.store.addSchedule(name: "Must not be added", workflowID: value.id, trigger: .interval(seconds: 60))
            #expect(await f.store.scheduleLedger.definitionSnapshot().definitions.isEmpty)
            await gate.release(); try await removal.value
            await f.store.addSchedule(name: "Still unavailable", workflowID: value.id, trigger: .interval(seconds: 60))
            #expect(await f.store.scheduleLedger.definitionSnapshot().definitions.isEmpty && f.store.configuration.workflows.isEmpty)
        }
    }
    @Test func publishedBusyCallbacksCannotReenterMutationOwners() async throws {
        try await withSourceRemovalFixture { f, _ in
            var attempts = 0
            let subscription = f.store.$scheduleBusy.dropFirst().filter { $0 }.sink { _ in
                MainActor.assumeIsolated { attempts += 1; #expect(f.store.beginScheduleMutation() == nil) }
            }
            let owner = try #require(f.store.beginScheduleMutation()); f.store.finishScheduleMutation(owner)
            subscription.cancel(); #expect(attempts == 1)
        }
    }
    @Test func oldEditorCannotRecreateRemovedWorkflowAndNewCreatesANewID() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = try makeRemovalWorkflow(in: f), session = WorkspaceSession()
            session.editWorkflow(value, in: f.store); session.workflowDraft.name = "Keep synthetic draft"
            let review = try await f.store.reviewSourceRemoval(.workflow(value.id))
            try await f.store.removeSource(review, isCurrent: { true })
            #expect(!session.saveWorkflow(in: f.store) && session.workflowDraft.name == "Keep synthetic draft" && f.store.configuration.workflows.isEmpty)
            session.newWorkflow(); session.workflowDraft.name = "Explicit new synthetic"
            #expect(session.workflowDraft.id != value.id && session.saveWorkflow(in: f.store))
            #expect(!f.store.removeWorkflow(session.workflowDraft.id))
        }
    }
    @Test func unicodeByteChangeAndNewReferencesInvalidateConfirmation() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = try makeRemovalWorkflow(in: f, name: "Synthetic Café"), review = try await f.store.reviewSourceRemoval(.workflow(value.id))
            f.store.configuration.workflows[0].name = "Synthetic Cafe\u{301}"
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Expected byte change rejection") } catch { #expect(error as? SourceRemovalError == .changed) }
            let fresh = try await f.store.reviewSourceRemoval(.workflow(value.id))
            f.store.configuration.collections = [try .init(name: "Added reference", commandIDs: ["workflow." + value.id.uuidString])]
            do { try await f.store.removeSource(fresh, isCurrent: { true }); Issue.record("Expected new reference rejection") } catch { #expect(error as? SourceRemovalError == .changed) }
        }
    }
    @Test func explicitOrphanRepairIncludesOnlyMissingWorkflowPreferences() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = try makeRemovalWorkflow(in: f), missing = "workflow." + UUID().uuidString, retained = "workflow." + value.id.uuidString
            f.store.configuration.preferences.favorites = [missing, retained, "unknown.synthetic"]
            let review = f.store.reviewDeletedToolPreferences()
            #expect(review.entries.map(\.id) == [missing])
            #expect(f.store.clearDeletedToolPreferences(review))
            #expect(f.store.configuration.preferences.favorites == [retained, "unknown.synthetic"])
        }
    }
    @Test func inFlightWorkflowKeepsItsSnapshotAndStaleCatalogCannotRestoreRecent() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = WorkflowDefinition(name: "Synthetic frozen run", steps: [.init(operation: .manualInput), .init(operation: .transform(.uppercase), input: .previousOutput)])
            #expect(f.store.saveWorkflow(value))
            let item = try #require(f.store.catalog.first { $0.id == "workflow." + value.id.uuidString })
            let run = try #require(f.store.runWorkflow(value, input: "Synthetic initial input"))
            try await f.eventually { !f.store.pendingWorkflowInputs.isEmpty }
            let request = try #require(f.store.pendingWorkflowInputs.first)
            let review = try await f.store.reviewSourceRemoval(.workflow(value.id))
            try await f.store.removeSource(review, isCurrent: { true })
            #expect(try f.task(run).isRunning && f.store.pendingWorkflowInputs.first?.id == request.id)
            f.store.execute(item)
            #expect(f.store.configuration.preferences.recent[item.id] == nil && f.store.tasks.count == 1)
            f.store.resolveWorkflowInput(request.id, value: "Synthetic frozen answer")
            try await f.drain(run)
            #expect(try f.task(run).status == .completed && f.task(run).output == "SYNTHETIC FROZEN ANSWER")
            #expect(f.store.configuration.workflows.isEmpty)
        }
    }
}
