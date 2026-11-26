import SwiftUI
import AICore
import KeyDockUI

extension AIScene {
    var title: String {
        switch self {
        case .text: L("General text actions")
        case .translation: L("Translation")
        case .summary: L("Summarization")
        case .commandExplanation: L("Command explanation")
        case .commandProposal: L("Command proposals")
        case .readOnlyAgent: L("Read-only agent")
        case .agent: L("Agent profiles")
        case .activity: L("Usage insights")
        case .workflow: L("Workflow AI steps")
        }
    }
}
extension AIReasoningSelection {
    var title: String {
        switch self {
        case .inherit: L("Inherit from parent")
        case .modelDefault: L("Model default · omit parameter")
        case .none: L("No reasoning · explicit none")
        case .low: L("Low reasoning")
        case .medium: L("Medium reasoning")
        case .high: L("High reasoning")
        case .xhigh: L("Extra high reasoning")
        case .max: L("Maximum reasoning")
        }
    }
}

/// 设置、动作和Agent共享；所有有效值来自执行解析器，页面打开不联网或读取凭据。
struct AIModelSettingsFields: View {
    @Binding var options: AIModelOptions
    let endpoint: String
    let globalModel: String
    let settings: AIModelSettings
    let scene: AIScene
    var isGlobal = false
    var isScenario = false
    var localHTTP = false
    var language = "system"
    var requiresTools = false
    private var official: Bool { URL(string: endpoint).map(AIModelCatalog.isOfficial) ?? false }
    private var declaredReasoning: Bool { URL(string: endpoint).map { settings.declaredReasoning(for: $0) } ?? false }
    private var selectedModel: String {
        AIModelResolver.modelID(globalModel: isGlobal ? options.model : globalModel, settings: settings,
            scene: isGlobal ? nil : scene, override: isGlobal ? .init() : options)
    }
    private var capability: AIModelCapability? {
        guard let url = URL(string: endpoint) else { return nil }
        return AIModelCatalog.capability(model: selectedModel, endpoint: url)
    }
    private var contextTitle: String { isGlobal ? L("Global AI defaults") : scene.title }
    private var originTitle: String {
        let origin = isGlobal ? AIModelOrigin.globalDefault : AIModelResolver.modelOrigin(settings: settings, scene: scene, override: isScenario ? .init() : options)
        return switch origin {
        case .globalDefault: L("Global default")
        case .scenarioDefault: L("Scenario default") + " · " + scene.title
        case .definitionOverride: L("Definition override")
        }
    }
    private var effective: FrozenAIExecutionSettings? {
        guard let url = URL(string: endpoint) else { return nil }
        var inherited = settings
        if isGlobal { inherited.defaults = options; inherited.defaults.model = ""; inherited.scenes = [:] }
        return try? AIModelResolver.resolve(endpoint: url, globalModel: isGlobal ? options.model : globalModel, settings: inherited,
            scene: scene, override: isGlobal ? .init() : options,
            outputLanguage: AIResponseLanguage(preference: language).rawValue, allowsLocalHTTP: localHTTP, requiresTools: requiresTools)
    }
    private var reasoningChoices: [AIReasoningSelection] {
        var values: [AIReasoningSelection] = isGlobal ? [.modelDefault] : [.inherit, .modelDefault]
        values += capability?.efforts ?? (declaredReasoning ? [.none, .low, .medium, .high, .xhigh, .max] : [])
        if !values.contains(options.reasoning) { values.append(options.reasoning) }
        return values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("Model selection"), selection: $options.model) {
                Text(isGlobal ? L("Choose a model") : L("Inherit from parent")).tag("")
                ForEach(AIModelCatalog.models) { model in
                    Text(model.displayName + " · " + (model.deprecated ? L("Deprecated model") : (official ? L("Recommended model") : L("Catalog model · verify service support")))).tag(model.id)
                }
                if !options.model.isEmpty && !AIModelCatalog.models.contains(where: { $0.id.utf8.elementsEqual(options.model.utf8) }) {
                    Text(options.model + " · " + L("Custom model · capabilities unknown")).tag(options.model)
                }
            }.accessibilityLabel(contextTitle + " · " + L("Model selection"))
            TextField(L("Exact model ID"), text: $options.model)
                .textFieldStyle(.roundedBorder).accessibilityLabel(contextTitle + " · " + L("Exact model ID"))
            Picker(L("API protocol"), selection: $options.requestProtocol) {
                if !isGlobal { Text(L("Inherit from parent")).tag(AIProtocolSelection.inherit) }
                Text(L("Automatic protocol")).tag(AIProtocolSelection.automatic)
                Text("Chat Completions").tag(AIProtocolSelection.chatCompletions)
                Text("Responses").tag(AIProtocolSelection.responses)
            }
            Picker(L("Reasoning effort"), selection: $options.reasoning) {
                ForEach(reasoningChoices, id: \.self) { effort in Text(effort.title).tag(effort) }
            }.accessibilityLabel(contextTitle + " · " + L("Reasoning effort"))
            if !isGlobal {
                Toggle(L("Override output token limit"), isOn: Binding(get: { options.maxOutputTokens != nil }, set: { options.maxOutputTokens = $0 ? 2048 : nil }))
            }
            if options.maxOutputTokens != nil {
                TextField(L("Maximum output tokens"), value: Binding(get: { options.maxOutputTokens ?? 2048 }, set: { options.maxOutputTokens = $0 }), format: .number.grouping(.never))
            }
            if let effective {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Effective model") + ": " + effective.configuration.model).fontWeight(.medium)
                    Text(L("Model source") + ": " + originTitle)
                    Text((effective.configuration.requestProtocol == .responses ? "Responses" : "Chat Completions") + " · " + (effective.configuration.reasoningEffort.flatMap { AIReasoningSelection(rawValue: $0)?.title } ?? L("Model default")) + " · " + String(effective.configuration.maxOutputTokens))
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                KDInlineNotice(L("These model settings cannot run. Check the endpoint, model, protocol, reasoning and token limit."))
            }
            if capability?.deprecated == true { KDInlineNotice(L("This model is deprecated. Your selection is preserved; choose a current model before its shutdown.")) }
            if capability == nil {
                Text(declaredReasoning ? L("Reasoning compatibility was declared manually for this service. Confirm the model and selected effort with your provider.") : L("Custom model capabilities are unverified. Model-default parameters remain available; no reasoning capability is assumed.")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("The output limit includes reasoning tokens. Higher effort can use the budget before a visible answer; KeyDock does not raise it automatically.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AIServiceModelSections: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    private var globalOptions: Binding<AIModelOptions> {
        Binding(get: { var value = session.aiModelSettings.defaults; value.model = session.modelName; return value }, set: { value in
            session.modelName = value.model; var defaults = value; defaults.model = ""; session.aiModelSettings.defaults = defaults
        })
    }
    var body: some View {
        Section(L("Global AI defaults")) {
            Toggle(L("Declare OpenAI-compatible reasoning for unverified models"), isOn: Binding(get: {
                URL(string: session.endpoint).map { session.aiModelSettings.declaredReasoning(for: $0) } ?? false
            }, set: { enabled in
                guard let endpoint = URL(string: session.endpoint) else { return }
                session.aiModelSettings.allowsUnverifiedReasoning = enabled
                session.aiModelSettings.reasoningServiceFingerprint = enabled ? AIServiceIdentity.fingerprint(endpoint) : nil
            }))
            AIModelSettingsFields(options: globalOptions, endpoint: session.endpoint, globalModel: session.modelName,
                settings: session.aiModelSettings, scene: .text, isGlobal: true, localHTTP: session.localHTTP, language: store.configuration.language)
            Text(L("Catalog verified on") + ": " + AIModelCatalog.verifiedOn).font(.caption).foregroundStyle(.secondary)
            Link(L("Open official model guidance"), destination: AIModelCatalog.sourceURL)
        }
        Section(L("Scenario defaults")) {
            Picker(L("AI scenario"), selection: $session.aiModelScene) {
                ForEach(AIScene.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            AIModelSettingsFields(options: Binding(get: { session.aiModelSettings.scenes[session.aiModelScene.rawValue] ?? .init() }, set: { value in
                session.aiModelSettings.scenes[session.aiModelScene.rawValue] = value.isInherited ? nil : value
            }), endpoint: session.endpoint, globalModel: session.modelName, settings: session.aiModelSettings, scene: session.aiModelScene,
                isScenario: true, localHTTP: session.localHTTP, language: store.configuration.language,
                requiresTools: session.aiModelScene == .agent || session.aiModelScene == .readOnlyAgent)
            Text(L("Explicit action or profile settings override the scenario. Each workflow AI step keeps its action override, then inherits Workflow AI steps.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
