import Foundation
import Combine
import AICore

@MainActor final class AIRateEditorDraft: ObservableObject, Identifiable {
    let id = UUID()
    let original: AIRateDefinition?
    @Published var value: AIRateDefinition
    @Published var notice: LocalizedNotice = .none
    @Published var closed = false
    var appeared = false
    init(value: AIRateDefinition, original: AIRateDefinition?) { self.value = value; self.original = original }
}

extension SettingsSession {
    func newAIRate(in store: WorkbenchModel) {
        guard canBeginSavedItemEditor, let endpoint = store.savedRateServiceEndpoint() else { return }
        aiRateDraft = .init(value: .init(endpointFingerprint: AIServiceIdentity.fingerprint(endpoint), model: store.configuration.model,
                                        currency: "USD", inputPerMillion: "", outputPerMillion: ""), original: nil)
    }
    func editAIRate(_ value: AIRateDefinition) {
        guard canBeginSavedItemEditor else { return }
        aiRateDraft = .init(value: value, original: value)
    }
    func aiRateDidAppear(_ id: UUID) { if let draft = aiRateDraft, draft.id == id, !draft.closed { draft.appeared = true } }
    func cancelAIRate(_ id: UUID) {
        guard let draft = aiRateDraft, draft.id == id else { return }
        draft.closed = true
        if draft.appeared { aiRateDismissing = true }
        else { aiRateDraft = nil; aiRateDismissing = false }
    }
    func aiRateDidDismiss(_ id: UUID) {
        guard aiRateDraft?.id == id else { return }
        aiRateDraft = nil; aiRateDismissing = false
    }
    @discardableResult func saveAIRate(_ draft: AIRateEditorDraft, in store: WorkbenchModel) -> Bool {
        guard aiRateDraft === draft, !draft.closed, !aiRateDismissing else { return false }
        guard store.saveAIRate(draft.value, replacing: draft.original) else { draft.notice = store.settingsNoticeMessage; return false }
        cancelAIRate(draft.id); return true
    }
    func removeAIRate(_ draft: AIRateEditorDraft, in store: WorkbenchModel) {
        guard aiRateDraft === draft, !draft.closed, !aiRateDismissing, let original = draft.original else { return }
        if store.removeAIRate(original) { cancelAIRate(draft.id) } else { draft.notice = store.settingsNoticeMessage }
    }
}

extension WorkbenchModel {
    /// 费率编辑只要求已保存的目的地；默认模型可空，由动作／Agent提供准确override。
    func savedRateServiceEndpoint() -> URL? {
        guard let endpoint = URL(string: configuration.endpoint), !configuration.endpoint.isEmpty,
              (try? AIProviderConfiguration(endpoint: endpoint, model: "rate-endpoint-validation", allowsLocalHTTP: configuration.localHTTP).validate()) != nil else { return nil }
        return endpoint
    }
    @discardableResult func saveAIRate(_ value: AIRateDefinition, replacing original: AIRateDefinition?) -> Bool {
        guard !isShuttingDown else { settingsNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return false }
        guard value.isValid else { settingsNoticeMessage = noticeKey("Enter an exact model, a three-letter uppercase currency and nonnegative decimal prices. Use up to 18 significant digits and 18 decimal places; leave no price blank."); return false }
        var next = configuration, rate = value
        if let original {
            guard original.id == value.id, next.aiRates.first(where: { $0.id == original.id }) == original else {
                settingsNoticeMessage = noticeKey("This rate was removed or changed. Your draft was kept; edit the current rate or create a new one."); return false
            }
        } else if next.aiRates.contains(where: { $0.id == value.id }) {
            settingsNoticeMessage = noticeKey("This rate was removed or changed. Your draft was kept; edit the current rate or create a new one."); return false
        }
        guard !next.aiRates.contains(where: { $0.id != value.id && $0.endpointFingerprint == value.endpointFingerprint && $0.model.utf8.elementsEqual(value.model.utf8) }) else {
            settingsNoticeMessage = noticeKey("A rate already exists for this exact service and model. Edit that rate instead."); return false
        }
        rate.revision = UUID()
        if let index = next.aiRates.firstIndex(where: { $0.id == value.id }) { next.aiRates[index] = rate }
        else {
            guard next.aiRates.count < 64 else { settingsNoticeMessage = noticeKey("The rate limit is 64 saved service and model pairs."); return false }
            next.aiRates.append(rate)
        }
        return commitSettingsConfiguration(next)
    }
    @discardableResult func removeAIRate(_ original: AIRateDefinition) -> Bool {
        guard configuration.aiRates.first(where: { $0.id == original.id }) == original else {
            settingsNoticeMessage = noticeKey("This rate was removed or changed. Your draft was kept; edit the current rate or create a new one."); return false
        }
        var next = configuration; next.aiRates.removeAll { $0.id == original.id }
        return commitSettingsConfiguration(next)
    }
    func rateMatchesCurrentService(_ rate: AIRateDefinition) -> Bool {
        guard let url = URL(string: configuration.endpoint), !configuration.endpoint.isEmpty else { return false }
        return rate.endpointFingerprint == AIServiceIdentity.fingerprint(url)
    }
}
