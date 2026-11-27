import Foundation
import Testing
import AICore
import MacAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct AIServiceQuickSetupTests {
    @Test func emptyConfigurationGetsDraftOnlyOpenAIPreset() async throws {
        let f = try RetentionFixture(); defer { Task { await f.cleanup() } }
        f.store.configuration.endpoint = ""; f.store.configuration.model = ""
        let session = SettingsSession(store: f.store)
        #expect(session.endpoint == AIServicePreset.openAIEndpoint)
        #expect(session.modelName.isEmpty && f.store.configuration.endpoint.isEmpty)
        #expect(!session.canLoadAIModels(in: f.store) && !session.canSaveQuickAIConfiguration(in: f.store))
        #expect(session.modelInventory == nil && f.store.tasks.isEmpty)
    }

    @Test func existingOfficialResponsesAndCompatibleEndpointsArePreserved() async throws {
        let f = try RetentionFixture(); defer { Task { await f.cleanup() } }
        for endpoint in ["https://api.openai.com/v1/responses", "https://compatible.invalid/v1/chat/completions"] {
            f.store.configuration.endpoint = endpoint; f.store.configuration.model = "existing-model"
            let session = SettingsSession(store: f.store)
            #expect(session.endpoint == endpoint && session.modelName == "existing-model")
        }
    }

    @Test func serviceSwitchClearsOldDraftAndPreservesCommittedConfiguration() async throws {
        let f = try RetentionFixture(); defer { Task { await f.cleanup() } }
        f.store.configuration.endpoint = "https://old.invalid/v1/chat/completions"
        f.store.configuration.model = "old-model"
        let session = SettingsSession(store: f.store)
        session.apiKey = "synthetic-only"
        session.modelInventory = .init(models: [.init("old-model")])
        session.selectAIService(.openAI)
        #expect(session.endpoint == AIServicePreset.openAIEndpoint && session.apiKey.isEmpty && session.modelName.isEmpty)
        #expect(session.modelInventory == nil && f.store.configuration.model == "old-model")
        session.apiKey = "new-synthetic-only"
        session.selectAIService(.compatible)
        #expect(session.endpoint.isEmpty && session.apiKey.isEmpty)
        #expect(f.store.configuration.endpoint == "https://old.invalid/v1/chat/completions")
    }

    @Test func accountListControlsRecommendationsAndExactUnknownIDs() {
        let preferred = AIModelCatalog.models.first { $0.recommended && !$0.deprecated }!
        let inventory = AIModelInventory(models: [.init(preferred.id), .init("new-model-2026"), .init("other-model")])
        let official = AIQuickModelChoices(endpoint: AIServicePreset.openAIEndpoint, inventory: inventory, query: "new-model", selected: preferred.id)
        #expect(official.recommended.map(\.id) == [preferred.id])
        #expect(official.listed == [.init("new-model-2026")])
        let unlisted = AIQuickModelChoices(endpoint: AIServicePreset.openAIEndpoint, inventory: .init(models: [.init("unknown-model")]), query: "", selected: "")
        #expect(unlisted.recommended.isEmpty && unlisted.listed == [.init("unknown-model")])
        let compatible = AIQuickModelChoices(endpoint: "https://api.openai.com.example.invalid/v1/chat/completions", inventory: inventory, query: "", selected: "")
        #expect(compatible.recommended.isEmpty && compatible.listed == inventory.models)
    }

    @Test func quickSaveRequiresKeyForOfficialAndSupportsCompatibleAnonymous() async throws {
        let f = try RetentionFixture(); defer { Task { await f.cleanup() } }
        f.store.configuration.endpoint = ""; f.store.configuration.model = ""
        let session = SettingsSession(store: f.store)
        session.modelName = "synthetic-model"
        #expect(!session.canSaveQuickAIConfiguration(in: f.store))
        session.selectAIService(.compatible)
        session.endpoint = "https://compatible.invalid/v1/chat/completions"
        session.modelName = "synthetic-model"
        #expect(session.canLoadAIModels(in: f.store) && session.canSaveQuickAIConfiguration(in: f.store))
        #expect(session.saveQuickAIConfiguration(in: f.store))
        #expect(f.store.configuration.model == "synthetic-model" && f.store.configuration.endpoint == session.endpoint)
    }

    @Test func openAIQuickSaveWritesOnlyTheExactCredentialSlotAndRetainsList() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-QuickSetup-" + UUID().uuidString)
        let other = "https://other.invalid/v1/chat/completions"
        var credentials = [other: "synthetic-other-key"]
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: true, clipboardReader: { nil },
            credentialReader: { credentials[$0] }, credentialWriter: { key, account in credentials[account] = key.isEmpty ? nil : key },
            applicationCatalog: ApplicationCatalog(roots: []))
        defer { Task { await store.shutdownAndWait(); try? FileManager.default.removeItem(at: directory) } }
        store.configuration.endpoint = ""; store.configuration.model = ""
        let session = SettingsSession(store: store)
        session.apiKey = "synthetic-openai-key"
        session.modelName = AIModelCatalog.models.first { $0.recommended && !$0.deprecated }!.id
        session.modelInventory = .init(models: [.init(session.modelName)])
        #expect(session.canLoadAIModels(in: store) && session.canSaveQuickAIConfiguration(in: store))
        #expect(session.saveQuickAIConfiguration(in: store))
        #expect(credentials[AIServicePreset.openAIEndpoint] == "synthetic-openai-key" && credentials[other] == "synthetic-other-key")
        #expect(session.apiKey.isEmpty && session.keyStored && session.modelInventory?.models == [.init(session.modelName)])
        #expect(store.savedServiceModels == [.init(session.modelName)])
        #expect(session.canSaveQuickAIConfiguration(in: store))
        let saved = try Data(contentsOf: directory.appendingPathComponent("configuration.json"))
        #expect(!String(decoding: saved, as: UTF8.self).contains("synthetic-openai-key"))
        session.selectAIService(.compatible)
        #expect(!session.hasAIServiceCredential(in: store) && session.modelInventory == nil)
    }
}
