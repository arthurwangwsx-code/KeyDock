import Foundation
import SwiftUI
import Testing
import AICore
import AutomationCore
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct AIModelIntegrationTests {
    @Test(arguments: [1024, 4096]) func enablingOutputOverrideCopiesTheParentEvenBeforeServiceSetup(_ limit: Int) {
        var settings = AIModelSettings(), draft = AIModelOptions()
        settings.defaults.maxOutputTokens = limit
        settings.scenes[AIScene.translation.rawValue] = .init(maxOutputTokens: 8192)
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let scenario = AIModelSettingsFields(options: binding, endpoint: "", globalModel: "", settings: settings, scene: .translation, isScenario: true)
        scenario.outputLimitOverride.wrappedValue = true
        #expect(draft.maxOutputTokens == limit)
        draft.maxOutputTokens = 512
        scenario.outputLimitOverride.wrappedValue = true
        #expect(draft.maxOutputTokens == 512)
        scenario.outputLimitOverride.wrappedValue = false
        #expect(draft.maxOutputTokens == nil)
        let definition = AIModelSettingsFields(options: binding, endpoint: "", globalModel: "", settings: settings, scene: .translation)
        definition.outputLimitOverride.wrappedValue = true
        #expect(draft.maxOutputTokens == 8192)
        definition.outputLimitOverride.wrappedValue = false
        #expect(AIModelResolver.outputTokenLimit(settings: settings, scene: .translation, override: draft) == 8192)
    }
    @Test func compatibleServiceKeepsListedCatalogModelProvenance() throws {
        let known = try #require(AIModelCatalog.models.first { $0.recommended })
        let fields = AIModelSettingsFields(options: .constant(.init()), endpoint: "https://synthetic.invalid/api",
            globalModel: known.id, settings: .init(), scene: .text, inventoryModels: [AIModelID(known.id)])
        #expect(fields.catalogLabel(known) == known.displayName + " · " + L("Listed by service · capabilities unverified"))
    }
    @Test func legacyMigrationIsIdempotentAndPreservesOverridesWithoutChangingProtocol() throws {
        var old = AppConfiguration()
        old.model = "old-exact-model"; old.aiActions = AppConfiguration.builtins
        old.aiActions[0].modelOverride = "legacy-translation-model"
        old.agents[0].modelOverride = "legacy-agent-model"
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        document["schemaVersion"] = 1; document.removeValue(forKey: "aiModelSettings"); document.removeValue(forKey: "aiSettingsRevision")
        document.removeValue(forKey: "savedApplicationActions")
        document["agents"] = (document["agents"] as! [[String: Any]]).map { value in var row = value; row.removeValue(forKey: "maxRunTokens"); return row }
        document["aiActions"] = (document["aiActions"] as! [[String: Any]]).map { value in var row = value; row.removeValue(forKey: "scene"); row.removeValue(forKey: "modelOptions"); return row }
        let bytes = try JSONSerialization.data(withJSONObject: document)
        let first = try JSONDecoder().decode(AppConfiguration.self, from: bytes)
        let second = try JSONDecoder().decode(AppConfiguration.self, from: bytes)
        #expect(first.schemaVersion == 4 && first.savedApplicationActions == nil && first.aiModelSettings == .legacy && first.aiSettingsRevision == second.aiSettingsRevision)
        #expect(first.model == "old-exact-model" && first.aiActions[0].modelOverride == "legacy-translation-model")
        #expect(first.aiActions[0].scene == .translation && first.aiActions[1].scene == .summary)
        #expect(first.agents[0].modelOverride == "legacy-agent-model" && first.agents[0].modelOptions == nil)
        let roundTrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(first))
        #expect(roundTrip.aiModelSettings == first.aiModelSettings && roundTrip.aiSettingsRevision == first.aiSettingsRevision)
        document["schemaVersion"] = 3
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: document)) }
    }
    @Test func nullV2SettingsOrRevisionNeverBecomeDefaultsOrRewriteTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ModelSchema-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("configuration.json")
        for key in ["aiModelSettings", "aiSettingsRevision"] {
            var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfiguration())) as? [String: Any])
            document[key] = NSNull()
            let bytes = try JSONSerialization.data(withJSONObject: document)
            try bytes.write(to: path)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: path)) }
            #expect(try Data(contentsOf: path) == bytes)
        }
    }
    @Test(arguments: ["request-settings", "responses-settings"])
    func productionRequestsConsumeSceneAndDefinitionSettingsAndStayFrozen(_ path: String) async throws {
        try await withStoreHTTPFixture(path: path) { f in
            var action = f.action; action.scene = .summary
            var settings = AIModelSettings(defaults: .init(requestProtocol: path == "responses-settings" ? .responses : .chatCompletions,
                reasoning: .low, maxOutputTokens: 2048), allowsUnverifiedReasoning: true,
                reasoningServiceFingerprint: AIServiceIdentity.fingerprint(URL(string: f.store.configuration.endpoint)!))
            settings.scenes[AIScene.summary.rawValue] = .init(model: "synthetic-summary-model", reasoning: .high, maxOutputTokens: 4096)
            f.store.configuration.aiModelSettings = settings
            let draft = f.store.createDraft(input: "Synthetic frozen input")
            let id = try #require(f.store.runAI(action: action, draft: draft))
            f.store.configuration.model = "changed-after-admission"
            f.store.configuration.aiModelSettings.scenes[AIScene.summary.rawValue] = .init(model: "changed-after-admission", reasoning: .none)
            try await f.drain(id)
            let task = try #require(f.store.tasks.first { $0.id == id })
            #expect(task.status == .completed && task.modelName == "synthetic-summary-model")
            let wire = try JSONDecoder().decode([String: JSONValue].self, from: Data(task.output.utf8))
            #expect(wire["model"] == .string("synthetic-summary-model") && wire["store"] == .bool(false))
            if path == "responses-settings" {
                #expect(wire["reasoning"] == .object(["effort": .string("high")]) && wire["max_output_tokens"] == .number(4096))
            } else { #expect(wire["reasoning_effort"] == .string("high") && wire["max_completion_tokens"] == .number(4096)) }
            action.modelOptions = .init(model: "synthetic-definition-model", reasoning: .modelDefault, maxOutputTokens: 3456)
            let nextDraft = f.store.createDraft(input: "Synthetic explicit override")
            let nextID = try #require(f.store.runAI(action: action, draft: nextDraft)); try await f.drain(nextID)
            let next = try #require(f.store.tasks.first { $0.id == nextID })
            let nextWire = try JSONDecoder().decode([String: JSONValue].self, from: Data(next.output.utf8))
            #expect(nextWire["model"] == .string("synthetic-definition-model"))
            #expect(nextWire["reasoning"] == .null && nextWire["reasoning_effort"] == .null)
            #expect(f.store.aiConversationReservations.isEmpty)
        }
    }
    @Test func unsupportedReasoningRejectsBeforeReceiptsAndNetwork() async throws {
        try await withStoreHTTPFixture(path: "request-settings") { f in
            f.store.configuration.aiModelSettings.defaults.reasoning = .high
            let draft = f.store.createDraft(input: "Synthetic rejected input")
            #expect(f.store.runAI(action: f.action, draft: draft) == nil)
            let stats = try await f.server.stats()
            #expect(stats["post_requests"] == 0 && f.store.tasks.isEmpty && f.store.executionReservations.isEmpty)
            #expect(await f.store.aiInvocationStore.list().isEmpty)
        }
    }
    @Test func savedSettingsABARevokesScheduledAIApprovalAndShortcutPreparation() async throws {
        let f = try RetentionFixture()
        do {
            let store = f.store
            store.configuration.endpoint = "https://synthetic.invalid/chat/completions"; store.configuration.model = "synthetic-A"
            let action = AIActionPreset(name: "Synthetic", prompt: "Synthetic")
            store.configuration.aiActions = [action]
            let workflow = WorkflowDefinition(name: "Synthetic workflow", steps: [.init(operation: .aiAction(action.id))])
            store.configuration.workflows = [workflow]
            store.rebuildCatalog()
            let approved = try store.scheduleFingerprint(workflow.id)
            let itemID = "ai." + action.id.uuidString
            let shortcut = try #require(store.prepareShortcutInvocation(id: itemID))
            var next = store.configuration; next.model = "synthetic-B"
            #expect(store.commitSettingsConfiguration(next))
            next = store.configuration; next.model = "synthetic-A"
            #expect(store.commitSettingsConfiguration(next))
            #expect(try store.scheduleFingerprint(workflow.id) != approved)
            store.performCommand(shortcut)
            #expect(!store.launcherNotice.isEmpty && store.tasks.isEmpty)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test func responsesContinuationReservationParticipatesInSharedAdmissionAndDrains() async throws {
        let f = try RetentionFixture(limits: .init(textBytes: 12 * 1_048_576))
        let first = UUID(), second = UUID()
        #expect(f.store.reserveExecution(first, aiConversation: true))
        #expect(!f.store.reserveExecution(second, aiConversation: true))
        #expect(f.store.aiConversationReservations == [first])
        f.store.finishExecutionReservation(first)
        #expect(f.store.aiConversationReservations.isEmpty)
        await f.cleanup()
    }
    @Test func commandReviewUsesExactRunAndBusyOrLateRequestsKeepTheirDrafts() async throws {
        let f = try RetentionFixture()
        do {
            let first = UUID(), second = UUID()
            try f.store.enqueueCommandReview(.init(name: "Synthetic first", executable: "/usr/bin/true"), runID: first)
            try f.store.enqueueCommandReview(.init(name: "Synthetic second", executable: "/usr/bin/true"), runID: second)
            let session = SettingsSession(store: f.store)
            session.beginNewAction()
            #expect(!session.beginCommandReview(second, in: f.store) && f.store.pendingCommandReviews.map(\.id) == [first, second])
            session.editedAction = nil
            #expect(session.beginCommandReview(second, in: f.store))
            #expect(session.editedCommandSourceRunID == second && session.editedCommand?.name == "Synthetic second")
            #expect(f.store.pendingCommandReviews.map(\.id) == [first])
            #expect(!session.beginCommandReview(first, in: f.store))
            session.editedCommand = nil; session.editedCommandSourceRunID = nil
            #expect(!session.beginCommandReview(second, in: f.store))
            #expect(session.beginCommandReview(first, in: f.store) && session.editedCommand?.name == "Synthetic first")
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test(arguments: [false, true])
    func auxiliaryTaskMetadataUsesItsFrozenSceneModel(_ readOnly: Bool) async throws {
        try await withStoreHTTPFixture(path: readOnly ? "agent" : "proposal") { f in
            let scene = readOnly ? AIScene.readOnlyAgent : .commandProposal
            let model = readOnly ? "synthetic-readonly-model" : "synthetic-proposal-model"
            f.store.configuration.aiModelSettings.scenes[scene.rawValue] = .init(model: model)
            let draft = f.store.createDraft(input: "Synthetic explicit auxiliary input")
            if readOnly { f.store.runReadOnlyAgent(draft: draft) } else { f.store.generateCommandProposal(draft: draft) }
            let id = try #require(f.store.tasks.first?.id)
            f.store.configuration.aiModelSettings.scenes[scene.rawValue] = .init(model: "changed-after-start")
            try await f.drain(id)
            let task = try #require(f.store.tasks.first { $0.id == id })
            #expect(task.modelName == model && task.status == (readOnly ? .completed : .draftReady))
            try f.assertNoCommandEffects()
        }
    }
}
