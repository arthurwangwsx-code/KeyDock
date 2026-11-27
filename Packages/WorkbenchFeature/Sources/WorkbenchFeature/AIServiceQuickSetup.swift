import Foundation
import SwiftUI
import AICore
import KeyDockUI

/// 预设是 UI 草稿，不是新的 API adapter 或持久凭据类型。
enum AIServicePreset: String, CaseIterable, Hashable {
    case openAI, compatible

    static let openAIEndpoint = "https://api.openai.com/v1/chat/completions"

    static func identify(_ endpoint: String) -> Self {
        guard let url = URL(string: endpoint), AIModelCatalog.isOfficial(url) else { return .compatible }
        return .openAI
    }
}

/// 只按已核实的目录与实际返回的准确 ID 组织选项；不猜测模型发布时间或生成能力。
struct AIQuickModelChoices {
    let recommended: [AIModelCapability]
    let listed: [AIModelID]

    init(endpoint: String, inventory: AIModelInventory?, query: String, selected: String) {
        let official = AIServicePreset.identify(endpoint) == .openAI
        let available = inventory.map { Set($0.models) }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ id: AIModelID, _ name: String) -> Bool {
            id == AIModelID(selected) || search.isEmpty || id.value.localizedCaseInsensitiveContains(search) || name.localizedCaseInsensitiveContains(search)
        }
        let preferred = official ? AIModelCatalog.models.filter { $0.recommended && !$0.deprecated && (available?.contains(AIModelID($0.id)) ?? true) && matches(AIModelID($0.id), $0.displayName) } : []
        let preferredIDs = Set(preferred.map { AIModelID($0.id) })
        recommended = preferred
        listed = (inventory?.models ?? []).filter { !preferredIDs.contains($0) && matches($0, $0.value) }
    }

    func contains(_ model: String) -> Bool {
        recommended.contains { AIModelID($0.id) == AIModelID(model) } || listed.contains(AIModelID(model))
    }
}

@MainActor extension SettingsSession {
    /// 仅新用户草稿采用预设，已有配置（含 Responses 地址）原样保留。
    func prepareInitialAIService() {
        if endpoint.isEmpty {
            endpoint = AIServicePreset.openAIEndpoint
            localHTTP = false
        }
    }

    func selectAIService(_ preset: AIServicePreset) {
        guard preset != AIServicePreset.identify(endpoint) else { return }
        // endpoint 的现有 didSet 撤销请求并清除旧草稿 key。
        endpoint = preset == .openAI ? AIServicePreset.openAIEndpoint : ""
        modelName = ""
        localHTTP = false
        tokenParameter = "max_completion_tokens"
        aiModelSettings.defaults.requestProtocol = .automatic
        aiModelSettings.defaults.reasoning = .modelDefault
        aiModelSettings.allowsUnverifiedReasoning = false
        aiModelSettings.reasoningServiceFingerprint = nil
    }

    func canLoadAIModels(in store: WorkbenchModel) -> Bool {
        guard !modelInventoryBusy, !store.isDesktopReview, hasValidDraftKey,
              let url = URL(string: endpoint), (try? AIModelInventoryClient.listEndpoint(for: url, allowsLocalHTTP: localHTTP)) != nil else { return false }
        return AIServicePreset.identify(endpoint) != .openAI || hasAIServiceCredential(in: store)
    }

    func hasAIServiceCredential(in store: WorkbenchModel) -> Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (keyStored && endpoint.utf8.elementsEqual(store.configuration.endpoint.utf8))
    }

    private var hasValidDraftKey: Bool {
        apiKey.isEmpty || (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && apiKey.utf8.count <= 16_384 && !apiKey.contains(where: { $0.isNewline || $0 == "\0" }))
    }

    func canSaveQuickAIConfiguration(in store: WorkbenchModel) -> Bool {
        guard !modelInventoryBusy, !store.isDesktopReview, hasValidDraftKey, let url = URL(string: endpoint),
              AIServicePreset.identify(endpoint) != .openAI || hasAIServiceCredential(in: store) else { return false }
        // 高级用户仍可仅保存场景覆盖；新用户应先选择全局默认模型。
        if modelName.isEmpty {
            return !aiModelSettings.scenes.isEmpty && (try? aiModelSettings.validate()) != nil
                && (try? AIProviderConfiguration(endpoint: url, model: "unconfigured-default", allowsLocalHTTP: localHTTP).validate()) != nil
        }
        var settings = aiModelSettings
        settings.scenes = [:] // 快速入口只校验全局层；场景覆盖仍独立展示和校验。
        return (try? AIModelResolver.resolve(endpoint: url, globalModel: modelName, settings: settings,
            scene: .text, outputLanguage: AIResponseLanguage(preference: store.configuration.language).rawValue,
            allowsLocalHTTP: localHTTP, tokenLimitParameter: TokenLimitParameter(rawValue: tokenParameter) ?? .maxCompletionTokens)) != nil
    }

    @discardableResult func saveQuickAIConfiguration(in store: WorkbenchModel) -> Bool {
        guard canSaveQuickAIConfiguration(in: store) else { return false }
        let verifiedInventory = modelInventory
        let verifiedEndpoint = endpoint
        let saved = store.saveAPIConfiguration(endpoint: endpoint, modelName: modelName, localHTTP: localHTTP,
            tokenParameter: tokenParameter, apiKey: apiKey, modelSettings: aiModelSettings)
        if saved {
            apiKey = ""
            keyStored = store.credentialExists()
            // 只有同一准确服务且本次成功保存时，复用此前显式 GET 的清单。
            if verifiedEndpoint.utf8.elementsEqual(store.configuration.endpoint.utf8), let verifiedInventory {
                modelInventory = verifiedInventory
                store.savedServiceModels = verifiedInventory.models
            }
        }
        apiSaveNotice = store.settingsNoticeMessage
        return saved
    }
}

struct AIServiceQuickSetupSections: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @State private var query = ""
    @State private var showExactModel = false

    private var preset: AIServicePreset { AIServicePreset.identify(session.endpoint) }
    private var choices: AIQuickModelChoices {
        .init(endpoint: session.endpoint, inventory: session.modelInventory, query: query, selected: session.modelName)
    }
    private var modelSelection: Binding<AIModelID> {
        Binding(get: { AIModelID(session.modelName) }, set: { session.modelName = $0.value })
    }

    var body: some View {
        Section(L("AI service setup")) {
            VStack(alignment: .leading, spacing: 5) {
                Label(L("Connect your AI service"), systemImage: "sparkles").font(.headline)
                Text(L("Choose a service, enter its API key, then load and choose a model.")).font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 3)
            Picker(L("AI service"), selection: Binding(get: { preset }, set: { session.selectAIService($0); query = "" })) {
                Text("OpenAI").tag(AIServicePreset.openAI)
                Text(L("Custom compatible service")).tag(AIServicePreset.compatible)
            }.pickerStyle(.segmented)
            if preset == .openAI {
                LabeledContent(L("Connection"), value: "api.openai.com")
                Link(L("Get an OpenAI API key"), destination: URL(string: "https://platform.openai.com/api-keys")!)
            } else {
                TextField(L("Full API endpoint"), text: $session.endpoint, prompt: Text("https://example.com/v1/chat/completions"))
                    .textFieldStyle(.roundedBorder)
            }
            SecureField(L("API key"), text: $session.apiKey,
                prompt: Text(session.keyStored && session.endpoint == store.configuration.endpoint ? L("Key stored · leave blank to keep") : L("Enter API key")))
                .textFieldStyle(.roundedBorder).disabled(!store.allowContextCapture)
            if session.keyStored && session.endpoint == store.configuration.endpoint && session.apiKey.isEmpty {
                Label(L("API key saved in Keychain"), systemImage: "checkmark.shield").foregroundStyle(.secondary).font(.caption)
            }
            HStack {
                Button(session.modelInventory == nil ? L("Connect & load models") : L("Refresh model list")) { session.refreshModelInventory(in: store) }
                    .buttonStyle(.borderedProminent).disabled(!session.canLoadAIModels(in: store))
                if session.modelInventoryBusy {
                    ProgressView().controlSize(.small)
                    Button(L("Cancel refresh")) { session.invalidateModelInventory(clear: false) }
                }
                Spacer(minLength: 0)
                if let inventory = session.modelInventory {
                    Label(L("Models returned") + ": " + String(inventory.models.count), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !session.modelInventoryNotice.rendered().isEmpty { KDInlineNotice(session.modelInventoryNotice.rendered()) }
            Text(store.allowContextCapture ? L("Model loading checks access to the model list, not generation. Your key is stored only when you save.") : L("Isolated preview: endpoints without keys can be tested. Use a regular build to store credentials."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Section(L("Default model")) {
            if let inventory = session.modelInventory {
                TextField(L("Search models"), text: $query).textFieldStyle(.roundedBorder)
                Text(inventory.fetchedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            Picker(L("Model selection"), selection: modelSelection) {
                Text(L("Choose a model")).tag(AIModelID(""))
                if !choices.recommended.isEmpty {
                    Section(L("Recommended model")) {
                        ForEach(choices.recommended) { model in Text(model.displayName + " · " + model.id).tag(AIModelID(model.id)) }
                    }
                }
                if !choices.listed.isEmpty {
                    Section(L("Models listed by this service")) {
                        ForEach(choices.listed) { model in Text(model.value).tag(model) }
                    }
                }
                if !session.modelName.isEmpty && !choices.contains(session.modelName) {
                    Text(session.modelName).tag(AIModelID(session.modelName))
                }
            }
            if preset == .openAI && session.modelInventory == nil {
                Text(L("Official recommendations are dated. Load the model list to see the models available to your account.")).font(.caption).foregroundStyle(.secondary)
            }
            if preset == .compatible || showExactModel {
                TextField(L("Exact model ID"), text: $session.modelName).textFieldStyle(.roundedBorder)
            }
            if preset == .openAI { Toggle(L("Enter model ID manually"), isOn: $showExactModel).toggleStyle(.checkbox) }
            if let inventory = session.modelInventory, !session.modelName.isEmpty {
                Text(inventory.models.contains(AIModelID(session.modelName)) ? L("Selected model is listed by this account") : L("Selected model is not in the current list; its availability is unverified."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !session.modelName.isEmpty && !session.modelInventoryBusy && !session.canSaveQuickAIConfiguration(in: store)
                && (preset == .compatible || session.hasAIServiceCredential(in: store)) {
                KDInlineNotice(L("Check the connection or advanced model settings before saving."))
            }
            HStack {
                Button(L("Save API configuration")) { session.saveQuickAIConfiguration(in: store) }
                    .buttonStyle(.borderedProminent).disabled(!session.canSaveQuickAIConfiguration(in: store))
                Spacer()
                Button(L("Remove API key"), role: .destructive) { store.removeCredential(); session.keyStored = store.credentialExists() }
                    .disabled(session.endpoint != store.configuration.endpoint || !session.keyStored)
            }
            if !session.apiSaveNotice.rendered().isEmpty { KDInlineNotice(session.apiSaveNotice.rendered()) }
        }
        .onChange(of: session.endpoint) { _, _ in query = "" }
    }
}
