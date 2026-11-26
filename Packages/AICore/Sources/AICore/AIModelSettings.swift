import Foundation
import CryptoKit

/// 场景是持久定义，不从名称、本地化文案或随机ID猜测。
public enum AIScene: String, Codable, CaseIterable, Sendable {
    case text, translation, summary, commandExplanation, commandProposal, readOnlyAgent, agent, activity, workflow
}

public enum AIRequestProtocol: String, Codable, CaseIterable, Sendable { case chatCompletions, responses }
public enum AIProtocolSelection: String, Codable, CaseIterable, Sendable { case inherit, automatic, chatCompletions, responses }
public enum AIReasoningSelection: String, Codable, CaseIterable, Sendable {
    case inherit, modelDefault, none, low, medium, high, xhigh, max
    public var wireValue: String? { self == .inherit || self == .modelDefault ? nil : rawValue }
}

/// 空model与nil预算分别表示继承；modelDefault明确省略wire参数，与none不同。
public struct AIModelOptions: Codable, Equatable, Sendable {
    public var model: String
    public var requestProtocol: AIProtocolSelection
    public var reasoning: AIReasoningSelection
    public var maxOutputTokens: Int?
    public init(model: String = "", requestProtocol: AIProtocolSelection = .inherit,
                reasoning: AIReasoningSelection = .inherit, maxOutputTokens: Int? = nil) {
        self.model = model; self.requestProtocol = requestProtocol; self.reasoning = reasoning; self.maxOutputTokens = maxOutputTokens
    }
    public var isInherited: Bool { self == AIModelOptions() }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model.utf8.elementsEqual(rhs.model.utf8) && lhs.requestProtocol == rhs.requestProtocol
            && lhs.reasoning == rhs.reasoning && lhs.maxOutputTokens == rhs.maxOutputTokens
    }
    public func validate() throws {
        guard model.utf8.count <= 256, !model.contains(where: { $0.isNewline || $0 == "\0" }),
              maxOutputTokens.map({ (1...32_768).contains($0) }) ?? true else { throw AIProviderError.invalidConfiguration }
    }
}

public struct AIModelSettings: Codable, Equatable, Sendable {
    public var defaults: AIModelOptions
    public var scenes: [String: AIModelOptions]
    public var allowsUnverifiedReasoning: Bool
    public var reasoningServiceFingerprint: String?
    public init(defaults: AIModelOptions = .init(requestProtocol: .automatic, reasoning: .modelDefault, maxOutputTokens: 2048),
                scenes: [String: AIModelOptions] = [:], allowsUnverifiedReasoning: Bool = false, reasoningServiceFingerprint: String? = nil) {
        self.defaults = defaults; self.scenes = scenes; self.allowsUnverifiedReasoning = allowsUnverifiedReasoning
        self.reasoningServiceFingerprint = reasoningServiceFingerprint
    }
    private enum CodingKeys: String, CodingKey { case defaults, scenes, allowsUnverifiedReasoning, reasoningServiceFingerprint }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(defaults: try c.decode(AIModelOptions.self, forKey: .defaults), scenes: try c.decodeIfPresent([String: AIModelOptions].self, forKey: .scenes) ?? [:],
            allowsUnverifiedReasoning: try c.decodeIfPresent(Bool.self, forKey: .allowsUnverifiedReasoning) ?? false,
            reasoningServiceFingerprint: try c.decodeIfPresent(String.self, forKey: .reasoningServiceFingerprint))
    }
    public func declaredReasoning(for endpoint: URL) -> Bool {
        allowsUnverifiedReasoning && reasoningServiceFingerprint == AIServiceIdentity.fingerprint(endpoint)
    }
    /// v1服务的完整Chat端点和有效行为保持不变，不替用户升级模型或协议。
    public static var legacy: Self { .init(defaults: .init(requestProtocol: .chatCompletions, reasoning: .modelDefault, maxOutputTokens: 2048)) }
    public func validate() throws {
        try defaults.validate()
        guard allowsUnverifiedReasoning ? reasoningServiceFingerprint.map(AIServiceIdentity.isFingerprint) == true : reasoningServiceFingerprint == nil else { throw AIProviderError.invalidConfiguration }
        guard defaults.model.isEmpty, defaults.requestProtocol != .inherit, defaults.reasoning != .inherit,
              defaults.maxOutputTokens != nil, scenes.count <= AIScene.allCases.count,
              scenes.keys.allSatisfy({ AIScene(rawValue: $0) != nil }) else { throw AIProviderError.invalidConfiguration }
        for value in scenes.values { try value.validate() }
    }
}

public struct AIModelCapability: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let recommended: Bool
    public let deprecated: Bool
    public let efforts: [AIReasoningSelection]
    public let chatToolsRequireNone: Bool
    public let toolsRequireResponses: Bool
}

/// 仅应用于官方OpenAI来源。/models清单不提供这些协议／推理能力。
public enum AIModelCatalog {
    public static let version = "openai-2026-11-26.1"
    public static let verifiedOn = "2026-11-26"
    public static let sourceURL = URL(string: "https://developers.openai.com/api/docs/guides/deployment-checklist")!
    public static let models: [AIModelCapability] = [
        .init(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol", recommended: true, deprecated: false,
              efforts: [.low, .medium, .high, .xhigh, .max], chatToolsRequireNone: false, toolsRequireResponses: true),
        .init(id: "gpt-6.2-astra", displayName: "GPT-6.2 Astra", recommended: true, deprecated: false,
              efforts: [.low, .medium, .high, .xhigh, .max], chatToolsRequireNone: false, toolsRequireResponses: true),
        .init(id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra", recommended: true, deprecated: false,
              efforts: [.none, .low, .medium, .high, .xhigh, .max], chatToolsRequireNone: false, toolsRequireResponses: true),
        .init(id: "gpt-6-luna", displayName: "GPT-6 Luna", recommended: true, deprecated: false,
              efforts: [.none, .low, .medium, .high, .xhigh, .max], chatToolsRequireNone: true, toolsRequireResponses: false),
        .init(id: "gpt-4.1-mini", displayName: "GPT-4.1 mini", recommended: false, deprecated: true,
              efforts: [], chatToolsRequireNone: false, toolsRequireResponses: false)
    ]
    public static func isOfficial(_ endpoint: URL) -> Bool {
        endpoint.scheme?.lowercased() == "https" && endpoint.host?.lowercased() == "api.openai.com"
            && (endpoint.port == nil || endpoint.port == 443) && endpoint.user == nil && endpoint.password == nil
            && endpoint.query == nil && endpoint.fragment == nil
            && ["/v1/chat/completions", "/v1/responses"].contains(endpoint.path)
    }
    public static func capability(model: String, endpoint: URL) -> AIModelCapability? {
        guard isOfficial(endpoint) else { return nil }
        return models.first { $0.id.utf8.elementsEqual(model.utf8) }
    }
    /// 最后一道wire门禁还要按实际tools复查，不能只信UI／上游预检。
    public static func validate(_ configuration: AIProviderConfiguration, requiresTools: Bool) throws {
        let value = capability(model: configuration.model, endpoint: configuration.endpoint)
        if let effort = configuration.reasoningEffort {
            guard let selection = AIReasoningSelection(rawValue: effort), selection.wireValue != nil,
                  value.map({ $0.efforts.contains(selection) }) ?? configuration.allowsUnverifiedReasoning else { throw AIModelSettingsError.unsupportedReasoning }
        }
        if requiresTools, configuration.requestProtocol == .chatCompletions, let value {
            guard !value.toolsRequireResponses, !value.chatToolsRequireNone || configuration.reasoningEffort == "none" else { throw AIModelSettingsError.toolsRequireResponses }
        }
    }
}

/// 一次调用只消费这份不可变设置；指纹无密钥、输入或opaque推理内容。
public struct FrozenAIExecutionSettings: Equatable, Sendable {
    public let scene: AIScene
    public let credentialAccount: String
    public let configuration: AIProviderConfiguration
    public let outputLanguage: String
    public let capabilityVersion: String
    public let fingerprint: String
}

public enum AIModelResolver {
    /// 页面在其他参数无效时仍可显示准确选择；nil场景专门表示全局层。
    public static func modelID(globalModel: String, settings: AIModelSettings, scene: AIScene?, override: AIModelOptions = .init(), legacyModelOverride: String = "") -> String {
        let explicit = override.model.isEmpty ? legacyModelOverride : override.model
        if !explicit.isEmpty { return explicit }
        let sceneModel = scene.flatMap { settings.scenes[$0.rawValue]?.model } ?? ""
        return sceneModel.isEmpty ? globalModel : sceneModel
    }
    public static func resolve(endpoint: URL, globalModel: String, settings: AIModelSettings,
                               scene: AIScene, override: AIModelOptions = .init(), legacyModelOverride: String = "",
                               outputLanguage: String, allowsLocalHTTP: Bool = false,
                               tokenLimitParameter: TokenLimitParameter = .maxCompletionTokens,
                               requiresTools: Bool = false) throws -> FrozenAIExecutionSettings {
        try settings.validate(); try override.validate()
        let sceneValue = settings.scenes[scene.rawValue] ?? .init()
        let model = modelID(globalModel: globalModel, settings: settings, scene: scene, override: override, legacyModelOverride: legacyModelOverride)
        let protocolValue = override.requestProtocol != .inherit ? override.requestProtocol
            : (sceneValue.requestProtocol != .inherit ? sceneValue.requestProtocol : settings.defaults.requestProtocol)
        let effort = override.reasoning != .inherit ? override.reasoning
            : (sceneValue.reasoning != .inherit ? sceneValue.reasoning : settings.defaults.reasoning)
        let budget = override.maxOutputTokens ?? sceneValue.maxOutputTokens ?? settings.defaults.maxOutputTokens!
        let capability = AIModelCatalog.capability(model: model, endpoint: endpoint)
        let declaredReasoning = settings.declaredReasoning(for: endpoint)
        let protocolKind: AIRequestProtocol
        switch protocolValue {
        case .automatic: protocolKind = capability?.recommended == true || endpoint.path.hasSuffix("/responses") ? .responses : .chatCompletions
        case .chatCompletions: protocolKind = .chatCompletions
        case .responses: protocolKind = .responses
        case .inherit: throw AIProviderError.invalidConfiguration
        }
        if effort.wireValue != nil {
            guard capability.map({ $0.efforts.contains(effort) }) ?? declaredReasoning else { throw AIModelSettingsError.unsupportedReasoning }
        }
        if requiresTools, protocolKind == .chatCompletions, let capability {
            guard !capability.toolsRequireResponses,
                  !capability.chatToolsRequireNone || effort == .none else { throw AIModelSettingsError.toolsRequireResponses }
        }
        var wireEndpoint = endpoint
        if AIModelCatalog.isOfficial(endpoint) {
            var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            parts.path = protocolKind == .responses ? "/v1/responses" : "/v1/chat/completions"
            wireEndpoint = parts.url!
        }
        let config = AIProviderConfiguration(endpoint: wireEndpoint, model: model, allowsLocalHTTP: allowsLocalHTTP,
            tokenLimitParameter: tokenLimitParameter, requestProtocol: protocolKind, reasoningEffort: effort.wireValue,
            maxOutputTokens: budget, serviceEndpoint: endpoint, allowsUnverifiedReasoning: declaredReasoning)
        try config.validate()
        try AIModelCatalog.validate(config, requiresTools: requiresTools)
        struct Stamp: Encodable {
            let policyVersion: Int, scene: String, credentialAccount: String, language: String, capabilityVersion: String
            let configuration: AIProviderConfiguration
        }
        let version = capability == nil ? (declaredReasoning ? "custom-declared-reasoning-v1" : "custom-unknown-v1") : AIModelCatalog.version
        let stamp = Stamp(policyVersion: 1, scene: scene.rawValue, credentialAccount: endpoint.absoluteString,
            language: outputLanguage, capabilityVersion: version, configuration: config)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fingerprint = SHA256.hash(data: try encoder.encode(stamp)).map { String(format: "%02x", $0) }.joined()
        return .init(scene: scene, credentialAccount: endpoint.absoluteString, configuration: config,
                     outputLanguage: outputLanguage, capabilityVersion: version, fingerprint: fingerprint)
    }
}

public enum AIModelSettingsError: Error, Equatable, Sendable { case unsupportedReasoning, toolsRequireResponses }

public enum AIModelOrigin: Equatable, Sendable { case globalDefault, scenarioDefault, definitionOverride }
public extension AIModelResolver {
    static func modelOrigin(settings: AIModelSettings, scene: AIScene?, override: AIModelOptions = .init(), legacyModelOverride: String = "") -> AIModelOrigin {
        if !override.model.isEmpty || !legacyModelOverride.isEmpty { return .definitionOverride }
        if let scene, settings.scenes[scene.rawValue]?.model.isEmpty == false { return .scenarioDefault }
        return .globalDefault
    }
}
