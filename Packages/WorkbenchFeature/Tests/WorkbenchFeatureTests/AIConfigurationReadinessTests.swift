import Foundation
import Testing
import MacAdapters
@testable import WorkbenchFeature

/// 使用合成配置和注入凭据计数器；准备检查不能触碰凭据或创建运行。
@Suite(.serialized) @MainActor struct AIConfigurationReadinessTests {
    private func withStore(_ body: (WorkbenchModel, () -> Int) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-AIReadiness-" + UUID().uuidString)
        var reads = 0
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: true,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in reads += 1; return nil }, credentialWriter: { _, _ in },
            applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        try body(store, { reads })
    }

    @Test func invalidOrMissingServiceCannotStartAndPreservesDraft() throws {
        try withStore { store, reads in
            let draft = store.createDraft(input: "Synthetic text kept while configuring")
            let revision = draft.revision, before = reads()
            for (endpoint, model, local) in [("", "", false), ("https://synthetic.invalid/chat/completions", " ", false),
                ("http://synthetic.invalid/chat/completions", "synthetic", true),
                ("https://synthetic.invalid/chat/completions#fragment", "synthetic", false)] {
                store.configuration.endpoint = endpoint; store.configuration.model = model; store.configuration.localHTTP = local
                #expect(!store.hasValidAIConfiguration() && !store.canRunAIFromInput(draft))
                #expect(store.runAIFromInput(draft) == nil && store.tasks.isEmpty)
                #expect(draft.input == "Synthetic text kept while configuring" && draft.revision == revision && draft.latestRunID == nil)
            }
            #expect(reads() == before)
        }
    }

    @Test func overrideAndLoopbackUseProductionRulesWithoutReadingAnonymousCredentials() throws {
        try withStore { store, reads in
            let draft = store.createDraft(input: "Synthetic model override"), before = reads()
            let index = try #require(store.configuration.aiActions.firstIndex { $0.id == draft.actionID })
            store.configuration.endpoint = "https://synthetic.invalid/chat/completions"; store.configuration.model = ""
            #expect(!store.canRunAIFromInput(draft))
            store.configuration.aiActions[index].modelOverride = "synthetic-override"
            #expect(store.canRunAIFromInput(draft) && store.hasValidAIConfiguration(modelOverride: "synthetic-override"))
            #expect(!store.hasValidAIConfiguration() && !store.hasValidAIConfiguration(modelOverride: String(repeating: "x", count: 257)))
            store.configuration.endpoint = "http://127.0.0.1:1/chat/completions"
            #expect(!store.canRunAIFromInput(draft))
            store.configuration.localHTTP = true
            #expect(store.canRunAIFromInput(draft))
            store.configuration.aiActions[index].modelOverride = ""
            #expect(!store.canRunAIFromInput(draft))
            store.configuration.model = "synthetic-global"
            #expect(store.canRunAIFromInput(draft))
            store.configuration.aiActions.remove(at: index)
            #expect(!store.canRunAIFromInput(draft) && store.runAIFromInput(draft) == nil)
            #expect(reads() == before && store.tasks.isEmpty)
        }
    }

    @Test func invalidatingConfigurationKeepsAnExistingRunCancellableWithoutReplay() async throws {
        try await withStoreHTTPFixture(path: "slow") { fixture in
            let store = fixture.store, input = "Synthetic running draft"
            let draft = store.createDraft(actionID: fixture.action.id, input: input)
            let id = try #require(store.runAIFromInput(draft))
            try await storeEventually { store.tasks.first(where: { $0.id == id })?.output.isEmpty == false }
            let endpoint = store.configuration.endpoint, model = store.configuration.model
            store.configuration.endpoint = ""; store.configuration.model = ""
            #expect(!store.canRunAIFromInput(draft) && store.runAIFromInput(draft) == nil)
            #expect(store.tasks.first(where: { $0.id == id })?.canCancel == true)
            store.cancelTask(id); try await fixture.drain(id)
            #expect(store.tasks.first(where: { $0.id == id })?.status == .cancelled)
            store.configuration.endpoint = endpoint; store.configuration.model = model
            #expect(store.canRunAIFromInput(draft))
            #expect(store.tasks.count == 1 && draft.latestRunID == id && draft.input == input)
            #expect(try await fixture.server.stats()["post_requests"] == 1)
        }
    }
}
