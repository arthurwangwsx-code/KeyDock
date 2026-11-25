import SwiftUI
import KeyDockUI

struct AIContentView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var draft: AIDraftDocument
    var compact = false
    var onBack: (() -> Void)?
    @FocusState private var inputFocused: Bool
    private var action: AIActionPreset? { store.configuration.aiActions.first { $0.id == draft.actionID } }
    private var task: RunningTaskItem? { store.tasks.first { $0.id == draft.latestRunID } }
    private var needsConfiguration: Bool { !store.hasValidAIConfiguration(modelOverride: action?.modelOverride ?? "") }
    private var auxiliaryActionsConfigured: Bool { store.hasValidAIConfiguration() }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(spacing: 12) {
                if let onBack { KDIconButton("chevron.left", label: L("Back"), action: onBack) }
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(task?.displayTitle ?? action?.displayName ?? L("AI workspace")).font(.system(size: compact ? 15 : 22, weight: .semibold))
                Spacer()
                if task?.isRunning == true, let id = task?.id { ProgressView().controlSize(.small); Button(L("Stop")) { store.cancelTask(id) } }
                else if action != nil {
                    if needsConfiguration {
                        Button(L("Configure AI")) { store.onOpenSettings?(.aiService) }.buttonStyle(.borderedProminent)
                    } else {
                        Button { store.runAIFromInput(draft) } label: {
                            HStack(spacing: 7) { Text(L("Run")); Text("⌘↩").font(.caption.monospaced()).opacity(0.8) }
                        }.buttonStyle(.borderedProminent).disabled(!store.canRunAIFromInput(draft))
                    }
                }
            }
            HStack(spacing: 6) {
                Text(draft.inputSourceTitle)
                Text("·"); Text(task?.modelName ?? (action?.modelOverride.isEmpty == false ? action!.modelOverride : (store.configuration.model.isEmpty ? L("No model configured") : store.configuration.model)))
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if needsConfiguration && task == nil { KDInlineNotice(L("Add an API endpoint and model in Settings. Your draft will stay here.")) }
            if action == nil { KDInlineNotice(L("This AI action is unavailable. Existing tasks keep their settings. Choose an action for your next task.")) }
            if !compact {
                Picker(L("AI action"), selection: Binding(get: { draft.actionID }, set: { draft.selectAction($0) })) {
                    if action == nil { Text(L("Choose an AI action")).tag(draft.actionID) }
                    ForEach(store.configuration.aiActions) { Text($0.displayName).tag(Optional($0.id)) }
                }.id(store.configuration.language).labelsHidden().frame(maxWidth: 320, alignment: .leading)
            }
            if task == nil || !compact {
                TextEditor(text: Binding(get: { draft.input }, set: { draft.editInput($0) })).focused($inputFocused).font(.system(size: 13)).frame(minHeight: 70, maxHeight: compact ? 100 : 150).scrollContentBackground(.hidden).padding(10).modifier(KDReadingSurface()).accessibilityLabel(L("AI input"))
                if !compact {
                    HStack {
                        Button(L("Use clipboard")) { store.useClipboardInput(draft) }
                        Button(L("Clear input")) { draft.clearInput() }.disabled(draft.input.isEmpty && draft.inputProvenance == nil)
                        Button(L("Suggest CLI")) { store.performUserInputAction { store.generateCommandProposal(draft: draft) } }.disabled(!auxiliaryActionsConfigured)
                        Button(L("Read-only agent")) { store.performUserInputAction { store.runReadOnlyAgent(draft: draft) } }.disabled(!auxiliaryActionsConfigured)
                        Spacer()
                    }.controlSize(.small)
                }
            }
            if compact && draft.input.isEmpty && task == nil { Text(L("No selected text. Enter text to begin.")).font(.caption).foregroundStyle(.secondary) }
            if let task {
                Text(L("Run input") + " · " + task.inputSourceTitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack { Text(task.state).font(.caption).foregroundStyle(.secondary); Spacer() }
                if let summary = task.aiUsageSummary { AIUsageStatusView(summary: summary, compact: compact) }
                ScrollView {
                    Text(task.output.isEmpty && task.isRunning ? L("Waiting for response…") : task.output)
                        .font(.system(size: compact ? 13 : 14)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(12)
                }.frame(maxWidth: .infinity, minHeight: compact ? 0 : 180, idealHeight: compact ? nil : 260, maxHeight: compact ? .infinity : 420).modifier(KDReadingSurface())
            } else if !compact { KDEmptyState(symbol: "sparkles", title: L("Ready when you are"), detail: L("Choose an action and add text. Only this input is sent to your model.")) }
            if !draft.notice.isEmpty { KDInlineNotice(draft.notice).lineLimit(compact ? 2 : 4) }
            if compact && task == nil { Spacer(minLength: 0) }
            HStack(spacing: 12) {
                if let id = task?.id {
                    Button(L("Copy")) { store.copyResult(id) }.disabled(task?.output.isEmpty != false)
                    if store.canReplaceResult(id) { Button(L("Replace original selection")) { store.replaceResult(id) } }
                }
                if compact && needsConfiguration && (action == nil || task?.isRunning == true) { Button(L("Configure AI")) { store.onOpenSettings?(.aiService) } }
                Spacer()
                if compact { Button(L("Open in Workspace")) { store.onOpenWorkspace?(.ai(draft.id)) } }
                else if !needsConfiguration || task != nil || action == nil { Button(L("Configure AI")) { store.onOpenSettings?(.aiService) } }
            }.controlSize(.small)
        }.padding(compact ? 22 : 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: draft.id) {
                guard draft.input.isEmpty else { return }
                // 先让输入控件注册到窗口焦点树，再请求首响应者。
                await Task.yield()
                inputFocused = true
            }
    }
}
