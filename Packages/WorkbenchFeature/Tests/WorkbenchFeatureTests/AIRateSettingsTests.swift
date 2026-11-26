import Foundation
import Testing
import AICore
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct AIRateSettingsTests {
    @Test func overrideOnlyConfigurationCanAddAndRebindARateWithoutDefaultModel() async throws {
        try await withSourceRemovalFixture { fixture, _ in
            let store = fixture.store; configure(store); store.configuration.model = ""
            let session = SettingsSession(store: store)
            #expect(!store.hasValidAIConfiguration() && store.hasValidAIConfiguration(modelOverride: "override-only"))
            session.newAIRate(in: store)
            let draft = try #require(session.aiRateDraft)
            #expect(draft.value.model.isEmpty)
            draft.value.model = "override-only"; draft.value.inputPerMillion = "1"; draft.value.outputPerMillion = "2"
            #expect(session.saveAIRate(draft, in: store))
            #expect(try store.provider(override: "override-only").usageRecorder?.frozenRate?.rate.inputPerMillion == "1")
            #expect(store.savedRateServiceEndpoint() != nil)
        }
    }
    @Test func rateEditorUsesSavedServiceAndNeverTouchesCredentialsOrNetwork() async throws {
        try await withSourceRemovalFixture { fixture, _ in
            let store = fixture.store; configure(store)
            let session = SettingsSession(store: store)
            session.endpoint = "https://example.com/uncommitted?synthetic-secret"
            session.modelName = "unsaved-model"
            session.newAIRate(in: store)
            let draft = try #require(session.aiRateDraft)
            #expect(draft.value.endpointFingerprint == AIServiceIdentity.fingerprint(URL(string: store.configuration.endpoint)!))
            #expect(draft.value.model == "synthetic-model" && draft.value.inputPerMillion.isEmpty)
            let unpriced = try store.provider()
            #expect(store.hasValidAIConfiguration() && unpriced.usageRecorder?.frozenRate == nil)
            session.aiRateDidAppear(draft.id)
            draft.value.inputPerMillion = "2"; draft.value.outputPerMillion = "4"
            #expect(session.saveAIRate(draft, in: store))
            #expect(store.configuration.aiRates.count == 1 && session.aiRateDraft === draft && draft.closed)
            #expect(session.aiRateDismissing)
            session.aiRateDidDismiss(draft.id)
            #expect(session.aiRateDraft == nil && !session.aiRateDismissing)
            let saved = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fixture.directory.appendingPathComponent("configuration.json")))
            #expect(saved.aiRates == store.configuration.aiRates)
        }
    }
    @Test func removedOrChangedRateRejectsOldEditorAndLateCallbacks() async throws {
        try await withSourceRemovalFixture { fixture, _ in
            let store = fixture.store; configure(store)
            #expect(store.saveAIRate(rate(store), replacing: nil))
            let original = try #require(store.configuration.aiRates.first), session = SettingsSession(store: store)
            session.editAIRate(original)
            let old = try #require(session.aiRateDraft)
            session.aiRateDidAppear(old.id)
            old.value.inputPerMillion = "7"
            #expect(store.removeAIRate(original))
            #expect(!session.saveAIRate(old, in: store) && session.aiRateDraft === old)
            #expect(old.value.inputPerMillion == "7" && !old.notice.rendered().isEmpty && store.configuration.aiRates.isEmpty)
            session.cancelAIRate(old.id)
            session.newAIRate(in: store); #expect(session.aiRateDraft === old && session.aiRateDismissing)
            session.aiRateDidDismiss(old.id)
            session.newAIRate(in: store)
            let newer = try #require(session.aiRateDraft)
            #expect(newer.value.id != original.id)
            #expect(!session.saveAIRate(old, in: store) && session.aiRateDraft === newer)
            session.aiRateDidDismiss(old.id)
            #expect(session.aiRateDraft === newer)
            #expect(store.configuration.aiRates.isEmpty)
        }
    }
    @Test func cancellationBeforePresentationDoesNotLeaveADismissGate() async throws {
        try await withSourceRemovalFixture { fixture, _ in
            let store = fixture.store; configure(store)
            let session = SettingsSession(store: store); session.newAIRate(in: store)
            let old = try #require(session.aiRateDraft)
            session.cancelAIRate(old.id)
            #expect(session.aiRateDraft == nil && !session.aiRateDismissing && session.canBeginSavedItemEditor)
            session.newAIRate(in: store)
            let newer = try #require(session.aiRateDraft)
            session.aiRateDidDismiss(old.id)
            #expect(session.aiRateDraft === newer && !session.aiRateDismissing)
        }
    }
    @Test func writeBeforeAndAfterFailuresRestoreFileAndKeepDraft() async throws {
        for failure in [SourceRemovalWriteRelay.Failure.before, .after] {
            try await withSourceRemovalFixture { fixture, relay in
                let store = fixture.store; configure(store)
                #expect(store.saveAIRate(rate(store), replacing: nil))
                let original = try #require(store.configuration.aiRates.first), file = fixture.directory.appendingPathComponent("configuration.json")
                let before = try Data(contentsOf: file), session = SettingsSession(store: store)
                session.editAIRate(original); let draft = try #require(session.aiRateDraft)
                draft.value.inputPerMillion = "9"; relay.failure = failure
                #expect(!session.saveAIRate(draft, in: store))
                #expect(try Data(contentsOf: file) == before)
                #expect(store.configuration.aiRates == [original] && session.aiRateDraft === draft && draft.value.inputPerMillion == "9")
                #expect(!draft.notice.rendered().isEmpty)
                #expect(session.saveAIRate(draft, in: store))
                #expect(store.configuration.aiRates.first?.inputPerMillion == "9")
            }
        }
    }
    @Test func exactUnicodeBindingsAndOverridesNeverTakeAnotherRate() async throws {
        try await withSourceRemovalFixture { fixture, _ in
            let store = fixture.store; configure(store)
            var first = rate(store); first.model = "é"
            var second = rate(store); second.model = "e\u{301}"; second.inputPerMillion = "5"
            #expect(store.saveAIRate(first, replacing: nil) && store.saveAIRate(second, replacing: nil))
            #expect(try store.provider(override: "é").usageRecorder?.frozenRate?.rate.inputPerMillion == "2")
            #expect(try store.provider(override: "e\u{301}").usageRecorder?.frozenRate?.rate.inputPerMillion == "5")
            #expect(try store.provider().usageRecorder?.frozenRate == nil)
            var duplicate = first; duplicate.id = UUID()
            #expect(!store.saveAIRate(duplicate, replacing: nil) && store.configuration.aiRates.count == 2)
            let frozen = try store.provider(override: "é")
            let saved = try #require(store.configuration.aiRates.first { $0.id == first.id })
            #expect(store.removeAIRate(saved))
            #expect(frozen.usageRecorder?.frozenRate?.rate.inputPerMillion == "2")
            #expect(try store.provider(override: "é").usageRecorder?.frozenRate == nil)
        }
    }
    @Test func invalidPricesDoNotWriteAndRateSheetBlocksExportAndOtherEditors() async throws {
        try await withSourceRemovalFixture { fixture, relay in
            let store = fixture.store; configure(store)
            let session = SettingsSession(store: store); session.newAIRate(in: store)
            let draft = try #require(session.aiRateDraft), writes = relay.writes
            draft.value.inputPerMillion = "NaN"; draft.value.outputPerMillion = "0"
            #expect(!session.saveAIRate(draft, in: store) && relay.writes == writes)
            #expect(!session.canBeginSavedItemEditor)
            session.prepareConfigurationExport(in: store); session.beginNewCommand()
            #expect(session.configurationExport == nil && session.editedCommand == nil && session.aiRateDraft === draft)
            draft.value.inputPerMillion = "0"
            #expect(session.saveAIRate(draft, in: store))
            #expect(store.hasValidAIConfiguration() && store.configuration.aiRates.first?.inputPerMillion == "0")
        }
    }
    @Test func rateExportHasExplicitFieldsBudgetsAndNoCommandIdentity() throws {
        var c = AppConfiguration()
        c.aiRates = [.init(endpointFingerprint: AIServiceIdentity.fingerprint(URL(string: "https://example.com/synthetic?secret=not-exported-here")!), model: "e\u{301}", currency: "USD", inputPerMillion: "0.000000000000000001", outputPerMillion: "0")]
        let frozen = try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.resources])
        let root = try ConfigurationExportFixture.object(frozen), resources = try #require(root["resources"] as? [String: Any])
        let exported = try #require((resources["aiRates"] as? [[String: Any]])?.first)
        #expect(resources["schemaVersion"] as? Int == 3 && frozen.definitionCount == 1)
        #expect(Set(exported.keys) == ["id", "revision", "endpointFingerprint", "model", "currency", "inputPerMillion", "outputPerMillion", "enabled", "unitTokens"])
        #expect((exported["model"] as? String)?.utf8.elementsEqual(c.aiRates[0].model.utf8) == true)
        #expect(!ExportDefinitionKind.rate.isCommand)
        let data = try JSONSerialization.data(withJSONObject: exported)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret="))
        c.aiRates.append(c.aiRates[0])
        #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.resources]) }
    }
    private func configure(_ store: WorkbenchModel) {
        store.configuration.endpoint = "https://example.com/synthetic?scope=one"; store.configuration.model = "synthetic-model"
    }
    private func rate(_ store: WorkbenchModel) -> AIRateDefinition {
        .init(endpointFingerprint: AIServiceIdentity.fingerprint(URL(string: store.configuration.endpoint)!), model: store.configuration.model,
              currency: "USD", inputPerMillion: "2", outputPerMillion: "4")
    }
}
