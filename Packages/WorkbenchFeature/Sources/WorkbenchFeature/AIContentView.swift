import SwiftUI
import KeyDockUI

struct AIContentView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var draft: AIDraftDocument
    var compact = false
    var onBack: (() -> Void)?
    var onRequestClose: (() -> Void)?
    @FocusState private var inputFocused: Bool
    @State private var closeIntent: AIDraftCloseIntent?
    private var action: AIActionPreset? { store.configuration.aiActions.first { $0.id == draft.actionID } }
    private var task: RunningTaskItem? { store.tasks.first { $0.id == draft.latestRunID } }
    private var needsConfiguration: Bool { !store.hasValidAIConfiguration(modelOverride: action?.modelOverride ?? "") }
    private var auxiliaryActionsConfigured: Bool { store.hasValidAIConfiguration() }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            heading
            if compact {
                ScrollView { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { content }
            if compact && !draft.notice.isEmpty { KDInlineNotice(draft.notice).lineLimit(2) }
            footer
            if !compact { HStack { Spacer(); closeDraftButton }.controlSize(.small) }
        }.disabled(draft.isClosing).padding(compact ? 22 : 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(item:$closeIntent) { intent in AIDraftCloseReviewView(store:store,intent:intent) }
            .task(id: draft.id) {
                guard draft.input.isEmpty else { return }
                // 先让输入控件注册到窗口焦点树，再请求首响应者。
                await Task.yield()
                inputFocused = true
            }
    }
    private var heading: some View {
        HStack(spacing: 12) {
                if let onBack { KDIconButton("chevron.left", label: L("Back"), action: onBack) }
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(task?.displayTitle ?? action?.displayName ?? L("AI workspace")).font(.system(size: compact ? 15 : 22, weight: .semibold))
                    .lineLimit(compact ? 1 : 3)
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
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(spacing: 6) {
                Text(draft.inputSourceTitle)
                Text("·"); Text(task?.modelName ?? (action?.modelOverride.isEmpty == false ? action!.modelOverride : (store.configuration.model.isEmpty ? L("No model configured") : store.configuration.model)))
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if store.isRemovedMCPSource(draft.inputProvenance) { Text(L("This MCP source was removed. The imported text is kept as a snapshot.")).font(.caption).foregroundStyle(.secondary) }
            if draft.isClosing { HStack { ProgressView().controlSize(.small); Text(L("Closing draft after its tasks finish…")).font(.caption) } }
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
                ReadOnlyTextPreview(text: task.output.isEmpty && task.isRunning ? L("Waiting for response…") : task.output,
                    accessibilityLabel: L("Task output"), pointSize: compact ? 13 : 14)
                    .frame(maxWidth: .infinity, minHeight: compact ? 140 : 180, idealHeight: compact ? 140 : 260, maxHeight: compact ? 140 : 420).modifier(KDReadingSurface())
            } else if !compact { KDEmptyState(symbol: "sparkles", title: L("Ready when you are"), detail: L("Choose an action and add text. Only this input is sent to your model.")) }
            if !compact && !draft.notice.isEmpty { KDInlineNotice(draft.notice).lineLimit(4) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if compact || task != nil {
                    Button(L("Copy")) { if let id = task?.id { store.copyResult(id) } }.disabled(task?.output.isEmpty != false)
                    if let id = task?.id, store.canReplaceResult(id) { Button(L("Replace original selection")) { store.replaceResult(id) } }
                }
                if compact && needsConfiguration && (action == nil || task?.isRunning == true) { Button(L("Configure AI")) { store.onOpenSettings?(.aiService) } }
            }
            Spacer()
            if compact {
                HStack(spacing: 12) {
                    Button(L("Open in Workspace")) { store.onOpenWorkspace?(.ai(draft.id)) }
                    closeDraftButton
                }.fixedSize()
            }
            else if !needsConfiguration || task != nil || action == nil { Button(L("Configure AI")) { store.onOpenSettings?(.aiService) } }
        }.buttonStyle(.bordered).controlSize(.small)
    }
    private var closeDraftButton: some View {
        Button(L("Close draft"),role:.destructive) {
            if let onRequestClose { onRequestClose() }
            else { closeIntent = AIDraftCloseIntent(document:draft) }
        }
    }
}
