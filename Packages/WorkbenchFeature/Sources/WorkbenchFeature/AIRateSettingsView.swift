import SwiftUI
import KeyDockUI
import AICore

/// 保留已出现的owner直到原sheet真正dismiss；取消未出现的sheet不留下永久门禁。
struct AIRateSheetHost: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var draft: AIRateEditorDraft
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { isPresented && !draft.closed }, set: { value in
                if !value { session.cancelAIRate(draft.id) }; isPresented = value
            }), onDismiss: { session.aiRateDidDismiss(draft.id) }) {
                AIRateEditorView(store: store, session: session, draft: draft).onAppear { session.aiRateDidAppear(draft.id) }
            }
            .onAppear { if !draft.closed { isPresented = true } else { session.aiRateDidDismiss(draft.id) } }
            .onChange(of: draft.closed) { _, value in if value { isPresented = false } }
    }
}

struct AIRateSettingsSection: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    var body: some View {
        Section(L("Optional model rates")) {
            Text(L("Rates are optional. Estimates use reported input and output tokens at your custom flat rates, without cache discounts, currency conversion or other provider charges. They are not a provider bill.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(store.configuration.aiRates) { rate in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rate.model).fontWeight(.medium).lineLimit(2)
                        Text(rate.currency + " · " + rate.inputPerMillion + " / " + rate.outputPerMillion).font(.caption.monospaced())
                        Text(L("Input / output per 1M tokens")).font(.caption).foregroundStyle(.secondary)
                        Text(store.rateMatchesCurrentService(rate) ? L("Bound to the saved API service") : L("Bound to a different API service")).font(.caption).foregroundStyle(.secondary)
                        Text(L("Service fingerprint") + ": " + String(rate.endpointFingerprint.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !rate.enabled { Text(L("Disabled")).font(.caption).foregroundStyle(.secondary) }
                    Button(L("Edit")) { session.editAIRate(rate) }.disabled(!session.canBeginSavedItemEditor)
                        .accessibilityLabel(L("Edit rate") + " · " + rate.model + " · " + rate.endpointFingerprint)
                }
            }
            Button(L("Add model rate")) { session.newAIRate(in: store) }.disabled(!session.canBeginSavedItemEditor || store.savedRateServiceEndpoint() == nil)
            if store.savedRateServiceEndpoint() == nil { Text(L("Save a valid API endpoint before adding a rate. No connection, default model or key is needed to edit rates.")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct AIRateEditorView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var draft: AIRateEditorDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.original == nil ? L("Add model rate") : L("Edit rate")).font(.title2.bold())
            Text(L("Saving or removing a rate affects new runs. Existing runs and history keep their frozen rate snapshots.")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Section(L("Service and model")) {
                    LabeledContent(L("API service"), value: store.rateMatchesCurrentService(draft.value) ? L("Saved API service") : L("Different API service"))
                    Text(L("Service fingerprint") + ": " + draft.value.endpointFingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    Button(L("Bind to the saved API service")) {
                        if let endpoint = store.savedRateServiceEndpoint() { draft.value.endpointFingerprint = AIServiceIdentity.fingerprint(endpoint) }
                    }.disabled(store.savedRateServiceEndpoint() == nil)
                    TextField(L("Exact request model"), text: $draft.value.model)
                    Toggle(L("Enable rate for new runs"), isOn: $draft.value.enabled)
                }
                Section(L("Price per 1,000,000 tokens")) {
                    TextField(L("Currency code"), text: $draft.value.currency)
                    TextField(L("Input token price"), text: $draft.value.inputPerMillion)
                    TextField(L("Output token price"), text: $draft.value.outputPerMillion)
                    Text(L("Use plain decimal numbers and an uppercase three-letter currency. Zero must be entered explicitly; missing rates and usage stay unknown.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped).frame(height: 350)
            if !draft.notice.rendered().isEmpty { KDInlineNotice(draft.notice.rendered()) }
            HStack {
                Button(L("Cancel")) { session.cancelAIRate(draft.id) }.keyboardShortcut(.cancelAction)
                if let original = draft.original {
                    Button(L("Remove saved rate"), role: .destructive) { session.removeAIRate(draft, in: store) }
                        .accessibilityLabel(L("Remove saved rate") + " · " + original.model)
                }
                Spacer()
                Button(L("Save rate")) { session.saveAIRate(draft, in: store) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 600)
    }
}
