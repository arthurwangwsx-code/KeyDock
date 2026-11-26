import Foundation
import Testing
import AgentCore
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct AgentBudgetConfigurationTests {
    @Test func canonicalNullableBudgetAndOlderVersionsAreUnambiguous() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var document = try #require(JSONSerialization.jsonObject(with: encoder.encode(AppConfiguration())) as? [String: Any])
        let initial = try #require(document["agents"] as? [[String: Any]])
        #expect(document["schemaVersion"] as? Int == 4 && initial[0]["maxRunTokens"] is NSNull)
        for version in [1, 2, 3] {
            var legacy = document; legacy["schemaVersion"] = version
            if version < 3 { legacy.removeValue(forKey: "savedApplicationActions") }
            if version == 1 { legacy.removeValue(forKey: "aiModelSettings"); legacy.removeValue(forKey: "aiSettingsRevision") }
            #expect(throws: (any Error).self) { try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)) }
            legacy["agents"] = initial.map { value in var copy = value; copy.removeValue(forKey: "maxRunTokens"); return copy }
            let decoded = try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(decoded.schemaVersion == 4 && decoded.agents[0].maxRunTokens == nil)
        }
        for invalid: Any in [0, -1, true, 1.5, "100", 1_000_000_001] {
            var rows = initial; rows[0]["maxRunTokens"] = invalid; document["agents"] = rows
            #expect(throws: (any Error).self) { try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: document)) }
        }
        var missing = initial; missing[0].removeValue(forKey: "maxRunTokens"); document["agents"] = missing
        #expect(throws: (any Error).self) { try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: document)) }
        document.removeValue(forKey: "agents")
        #expect(throws: (any Error).self) { try decoder.decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: document)) }
    }

    @Test func rawDraftSurvivesNavigationAndOnlyValidValuesCanSaveOrRun() async throws {
        try await withStoreHTTPFixture(path: "usage") { f in
            let session = WorkspaceSession()
            session.setAgentTokenThresholdEnabled(true); session.setAgentTokenThresholdText("not-a-number")
            session.agentProfile.name = "Synthetic other edit"
            #expect(session.agentRunTokenText == "not-a-number" && !session.hasValidAgentTokenThresholdDraft)
            #expect(!session.saveAgentProfile(in: f.store))
            #expect(f.store.runAgent(session.agentProfile, input: "Synthetic invalid draft") == nil)
            session.setAgentTokenThresholdEnabled(false)
            #expect(session.hasValidAgentTokenThresholdDraft && session.agentRunTokenText == "not-a-number")
            session.setAgentTokenThresholdEnabled(true)
            #expect(!session.hasValidAgentTokenThresholdDraft)
            session.setAgentTokenThresholdText(" 34 ")
            #expect(session.hasValidAgentTokenThresholdDraft && session.agentProfile.maxRunTokens == 34)
            #expect(session.saveAgentProfile(in: f.store))
            let persisted = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: f.directory.appendingPathComponent("configuration.json")))
            #expect(persisted.agents.contains { $0.id == session.agentProfile.id && $0.maxRunTokens == 34 })
            let stats = try await f.server.stats(); #expect(stats["post_requests"] == 0)
        }
    }

    @Test func thresholdChangesDefinitionAndUnsavedContractWithoutChangingOldGoldenProjection() async throws {
        try await withStoreHTTPFixture(path: "usage") { f in
            let off = AgentDefinition(), settings = try f.store.resolveAISettings(scene: .agent, requiresTools: true)
            let old = try RunDefinitionFingerprint.reference(off), disabled = try f.store.freezeAgentRunContract(off, settings: settings)
            var enabled = off; enabled.maxRunTokens = 100
            let new = try RunDefinitionFingerprint.reference(enabled), frozen = try f.store.freezeAgentRunContract(enabled, settings: settings)
            #expect(old != new && disabled.fingerprint != frozen.fingerprint)
            enabled.maxRunTokens = 200
            let edited = try f.store.freezeAgentRunContract(enabled, settings: settings)
            #expect(edited.fingerprint != frozen.fingerprint && frozen.maxRunTokens == 100)
            #expect(f.store.savedRunReference(.agent(enabled)) == nil)
        }
    }
}
