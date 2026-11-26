import Foundation
import Testing
import AICore

@Suite struct AIModelSettingsTests {
    let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    func resolve(_ settings: AIModelSettings = .init(), scene: AIScene = .text, override: AIModelOptions = .init(),
                 model: String = "gpt-6.2-sol", tools: Bool = false, language: String = "zh-Hans") throws -> FrozenAIExecutionSettings {
        try AIModelResolver.resolve(endpoint: endpoint, globalModel: model, settings: settings, scene: scene,
            override: override, outputLanguage: language, requiresTools: tools)
    }
    @Test func fieldsInheritIndependentlyAndDefinitionsWin() throws {
        var settings = AIModelSettings(defaults: .init(requestProtocol: .automatic, reasoning: .medium, maxOutputTokens: 4096))
        settings.scenes[AIScene.translation.rawValue] = .init(model: "gpt-6-luna", reasoning: .none)
        #expect(AIModelResolver.modelOrigin(settings: settings, scene: .translation, override: .init(maxOutputTokens: 8192)) == .scenarioDefault)
        #expect(AIModelResolver.modelOrigin(settings: settings, scene: .translation, override: .init(model: "explicit")) == .definitionOverride)
        #expect(AIModelResolver.modelOrigin(settings: settings, scene: nil) == .globalDefault)
        let scene = try resolve(settings, scene: .translation)
        #expect(scene.configuration.model == "gpt-6-luna")
        #expect(scene.configuration.reasoningEffort == "none")
        #expect(scene.configuration.maxOutputTokens == 4096)
        let explicit = try resolve(settings, scene: .translation, override: .init(model: "gpt-6.2-astra", reasoning: .modelDefault, maxOutputTokens: 8192))
        #expect(explicit.configuration.model == "gpt-6.2-astra")
        #expect(explicit.configuration.reasoningEffort == nil)
        #expect(explicit.configuration.maxOutputTokens == 8192)
        #expect(explicit.configuration.requestProtocol == .responses)
        #expect(explicit.credentialAccount == endpoint.absoluteString)
        #expect(explicit.configuration.endpoint.absoluteString == "https://api.openai.com/v1/responses")
    }
    @Test func oldModelOverridesRemainExactAndLegacyProtocolIsNotUpgraded() throws {
        let result = try AIModelResolver.resolve(endpoint: endpoint, globalModel: "", settings: .legacy, scene: .text,
            legacyModelOverride: "custom-exact-model", outputLanguage: "en")
        #expect(result.configuration.model == "custom-exact-model")
        #expect(result.configuration.requestProtocol == .chatCompletions)
        #expect(result.configuration.reasoningEffort == nil)
        #expect(result.capabilityVersion == "custom-unknown-v1")
    }
    @Test func latestToolProtocolAndReasoningAreValidatedBeforeAnyRequest() throws {
        #expect(throws: AIModelSettingsError.unsupportedReasoning) { try resolve(override: .init(reasoning: .none)) }
        #expect(throws: AIModelSettingsError.toolsRequireResponses) {
            try resolve(override: .init(requestProtocol: .chatCompletions), tools: true)
        }
        #expect(throws: AIModelSettingsError.toolsRequireResponses) {
            try resolve(override: .init(requestProtocol: .chatCompletions), model: "gpt-6-luna", tools: true)
        }
        let luna = try resolve(override: .init(requestProtocol: .chatCompletions, reasoning: .none), model: "gpt-6-luna", tools: true)
        #expect(luna.configuration.reasoningEffort == "none")
        #expect(try resolve(override: .init(reasoning: .max), tools: true).configuration.requestProtocol == .responses)
    }
    @Test(arguments: ["https://proxy.invalid/v1/chat/completions", "https://api.openai.com.evil.invalid/v1/chat/completions", "http://127.0.0.1/v1/chat/completions"])
    func customServicesDoNotInheritOfficialCapabilities(_ url: String) throws {
        let endpoint = URL(string: url)!
        #expect(AIModelCatalog.capability(model: "gpt-6.2-sol", endpoint: endpoint) == nil)
        #expect(throws: AIModelSettingsError.unsupportedReasoning) {
            try AIModelResolver.resolve(endpoint: endpoint, globalModel: "gpt-6.2-sol", settings: .init(), scene: .text,
                override: .init(reasoning: .low), outputLanguage: "en", allowsLocalHTTP: true)
        }
    }
    @Test func unknownAndDeprecatedIDsArePreservedWithoutRecommendation() throws {
        let exact = "my-custom-model-2026-11-26"
        let unknown = try resolve(model: exact)
        #expect(unknown.configuration.model == exact && unknown.capabilityVersion == "custom-unknown-v1")
        let old = try resolve(model: "gpt-4.1-mini")
        #expect(old.configuration.model == "gpt-4.1-mini")
        #expect(AIModelCatalog.models.first(where: { $0.id == old.configuration.model })?.deprecated == true)
        #expect(AIModelCatalog.models.filter(\.recommended).allSatisfy { !$0.deprecated })
    }
    @Test func settingsFingerprintFreezesEveryExecutionChoiceAndNeverContainsInput() throws {
        let original = try resolve()
        #expect(original == (try resolve()))
        #expect(original.fingerprint.count == 64)
        let alternatives = [try resolve(scene: .summary), try resolve(override: .init(reasoning: .low)),
            try resolve(override: .init(maxOutputTokens: 4096)), try resolve(language: "en"), try resolve(model: "gpt-6-luna")]
        #expect(alternatives.allSatisfy { $0.fingerprint != original.fingerprint })
        #expect(original.configuration.reasoningEffort == nil)
    }
    @Test func actualChatWireOmitsDefaultButSendsNoneAndBudget() throws {
        let frozen = try resolve(override: .init(requestProtocol: .chatCompletions, reasoning: .none, maxOutputTokens: 6789), model: "gpt-6-luna")
        let request = AIRequest(messages: [.init(role: "user", content: "synthetic")])
        let wire = try ChatCompletionsProvider(configuration: frozen.configuration, apiKey: "").makeURLRequest(request)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(wire.httpBody))
        #expect(body["model"] == .string("gpt-6-luna"))
        #expect(body["reasoning_effort"] == .string("none"))
        #expect(body["max_completion_tokens"] == .number(6789))
        #expect(body["store"] == .bool(false))
        let omitted = try resolve(override: .init(requestProtocol: .chatCompletions), model: "gpt-6-luna")
        let defaultWire = try ChatCompletionsProvider(configuration: omitted.configuration, apiKey: "").makeURLRequest(request)
        let defaultBody = try JSONDecoder().decode([String: JSONValue].self, from: #require(defaultWire.httpBody))
        #expect(defaultBody["reasoning_effort"] == nil)
        #expect(defaultBody["temperature"] == nil && defaultBody["n"] == nil)
        #expect(throws: AIProviderError.invalidRequest) {
            try ChatCompletionsProvider(configuration: frozen.configuration, apiKey: "").makeURLRequest(.init(messages: request.messages, maxTokens: 6790))
        }
    }
    @Test func oldProviderConfigurationDecodesWithOriginalDefaults() throws {
        let bytes = Data(#"{"endpoint":"https://example.invalid/chat","model":"synthetic","allowsLocalHTTP":false,"tokenLimitParameter":"max_tokens","timeout":15}"#.utf8)
        let value = try JSONDecoder().decode(AIProviderConfiguration.self, from: bytes)
        #expect(value.requestProtocol == .chatCompletions && value.reasoningEffort == nil && value.maxOutputTokens == 2048)
        #expect(value.tokenLimitParameter == .maxTokens && value.timeout == 15)
    }
    @Test func malformedScopesAndBudgetsAreRejected() throws {
        var settings = AIModelSettings()
        settings.scenes["guessed-localized-name"] = .init(model: "x")
        #expect(throws: AIProviderError.invalidConfiguration) { try resolve(settings) }
        #expect(throws: AIProviderError.invalidConfiguration) { try resolve(override: .init(maxOutputTokens: 0)) }
        #expect(throws: AIProviderError.invalidConfiguration) { try resolve(model: "bad\nmodel") }
    }
    @Test func customReasoningDeclarationIsBoundToOneExactServiceAndCannotOverrideVerifiedLimits() throws {
        let endpoint = URL(string: "https://synthetic-one.invalid/chat/completions")!
        var settings = AIModelSettings(allowsUnverifiedReasoning: true, reasoningServiceFingerprint: AIServiceIdentity.fingerprint(endpoint))
        settings.defaults.reasoning = .none
        let first = try AIModelResolver.resolve(endpoint: endpoint, globalModel: "synthetic", settings: settings, scene: .text, outputLanguage: "en")
        #expect(first.configuration.reasoningEffort == "none" && first.capabilityVersion == "custom-declared-reasoning-v1")
        #expect(throws: AIModelSettingsError.unsupportedReasoning) {
            try AIModelResolver.resolve(endpoint: URL(string: "https://synthetic-two.invalid/chat/completions")!, globalModel: "synthetic", settings: settings, scene: .text, outputLanguage: "en")
        }
        settings.reasoningServiceFingerprint = AIServiceIdentity.fingerprint(self.endpoint)
        #expect(throws: AIModelSettingsError.unsupportedReasoning) { try resolve(settings) }
    }
    @Test func canonicallyEquivalentModelIDsStayByteDistinct() throws {
        let first = "caf\u{e9}", second = "cafe\u{301}"
        #expect(AIModelOptions(model: first) != AIModelOptions(model: second))
        let a = try resolve(model: first), b = try resolve(model: second)
        #expect(a.configuration != b.configuration && a.fingerprint != b.fingerprint)
        let wire = try ChatCompletionsProvider(configuration: a.configuration, apiKey: "").makeURLRequest(.init(messages: [.init(role: "user", content: "synthetic")]))
        let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(wire.httpBody))
        #expect(body["model"]!.stringValue!.utf8.elementsEqual(first.utf8))
    }
    @Test func globalDisplayNeverBorrowsATextScenarioModel() {
        var settings = AIModelSettings()
        settings.scenes[AIScene.text.rawValue] = .init(model: "gpt-4.1-mini")
        #expect(AIModelResolver.modelID(globalModel: "", settings: settings, scene: nil) == "")
        #expect(AIModelResolver.modelID(globalModel: "", settings: settings, scene: .text) == "gpt-4.1-mini")
    }
}
