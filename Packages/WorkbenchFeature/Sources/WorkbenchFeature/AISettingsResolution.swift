import Foundation
import AICore

extension WorkbenchModel {
    func effectiveAIModelName(for action: AIActionPreset) -> String {
        let value = AIModelResolver.modelID(globalModel: configuration.model, settings: configuration.aiModelSettings,
            scene: action.scene ?? .text, override: action.modelOptions ?? .init(), legacyModelOverride: action.modelOptions == nil ? action.modelOverride : "")
        return value.isEmpty ? L("No model configured") : value
    }
    /// 只有成功写入的候选会发布revision；A→B→A仍需重新批准AI调度。
    func preparedAIConfiguration(_ value: AppConfiguration) -> AppConfiguration {
        struct Action: Encodable { let id: UUID; let model: String; let options: AIModelOptions?; let scene: AIScene? }
        struct Policy: Encodable {
            let endpoint: String, model: String, language: String, tokenParameter: String
            let localHTTP: Bool
            let settings: AIModelSettings
            let actions: [Action]
            let agents: [Action]
        }
        func stamp(_ c: AppConfiguration) -> String? {
            objectFingerprint(Policy(endpoint: c.endpoint, model: c.model, language: c.language, tokenParameter: c.tokenLimitParameter,
                localHTTP: c.localHTTP, settings: c.aiModelSettings,
                actions: c.aiActions.sorted { $0.id.uuidString < $1.id.uuidString }.map { .init(id: $0.id, model: $0.modelOverride, options: $0.modelOptions, scene: $0.scene) },
                agents: c.agents.sorted { $0.id.uuidString < $1.id.uuidString }.map { .init(id: $0.id, model: $0.modelOverride, options: $0.modelOptions, scene: .agent) }))
        }
        var next = value
        next.aiSettingsRevision = stamp(value) == stamp(configuration) ? configuration.aiSettingsRevision : UUID()
        return next
    }
    func resolveAISettings(scene: AIScene = .text, override: AIModelOptions = .init(), legacyModelOverride: String = "",
                           requiresTools: Bool = false) throws -> FrozenAIExecutionSettings {
        try requireGeneralRuntime()
        guard let endpoint = URL(string: configuration.endpoint), !configuration.endpoint.isEmpty else { throw AIProviderError.invalidConfiguration }
        return try AIModelResolver.resolve(endpoint: endpoint, globalModel: configuration.model, settings: configuration.aiModelSettings,
            scene: scene, override: override, legacyModelOverride: legacyModelOverride,
            outputLanguage: AIResponseLanguage(preference: configuration.language).rawValue,
            allowsLocalHTTP: configuration.localHTTP,
            tokenLimitParameter: TokenLimitParameter(rawValue: configuration.tokenLimitParameter) ?? .maxCompletionTokens,
            requiresTools: requiresTools)
    }
    func resolveAISettings(action: AIActionPreset, scene: AIScene? = nil) throws -> FrozenAIExecutionSettings {
        try resolveAISettings(scene: scene ?? action.scene ?? .text, override: action.modelOptions ?? .init(),
            legacyModelOverride: action.modelOptions == nil ? action.modelOverride : "")
    }
    func provider(settings: FrozenAIExecutionSettings) throws -> ResolvedAIProvider {
        try requireGeneralRuntime()
        let key = allowContextCapture ? (try credentialReader(settings.credentialAccount) ?? "") : ""
        return ResolvedAIProvider(configuration: settings.configuration, apiKey: key,
            usageRecorder: AIUsageRecorder(rate: AIRateDefinition.snapshot(in: configuration.aiRates, configuration: settings.configuration)))
    }
    func provider(action: AIActionPreset, scene: AIScene? = nil) throws -> ResolvedAIProvider {
        try provider(settings: resolveAISettings(action: action, scene: scene))
    }
}
