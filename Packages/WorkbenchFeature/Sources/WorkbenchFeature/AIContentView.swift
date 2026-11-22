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
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(spacing: 12) {
                if let onBack { Button(action: onBack) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help(L("Back")) }
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(task?.displayTitle ?? action?.displayName ?? L("AI workspace")).font(.system(size: compact ? 15 : 22, weight: .semibold))
                Spacer()
                if task?.isRunning == true, let id = task?.id { ProgressView().controlSize(.small); Button(L("Stop")) { store.cancelTask(id) }.keyboardShortcut(".", modifiers: .command) }
                else if let action { Button(L("Run")) { store.runAI(action: action, draft: draft) }.buttonStyle(.borderedProminent).disabled(draft.input.isEmpty) }
            }
            HStack(spacing: 6) {
                Text(task?.sourceApplication ?? task?.source?.title ?? draft.sourceTarget?.applicationName ?? draft.source.title)
                Text("·"); Text(task?.modelName ?? (action?.modelOverride.isEmpty == false ? action!.modelOverride : (store.configuration.model.isEmpty ? L("No model configured") : store.configuration.model)))
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if !compact {
                Picker(L("AI action"), selection: Binding(get: { draft.actionID }, set: { draft.selectAction($0) })) { ForEach(store.configuration.aiActions) { Text($0.displayName).tag(Optional($0.id)) } }.labelsHidden().frame(maxWidth: 320, alignment: .leading)
            }
            if task == nil || !compact {
                TextEditor(text: Binding(get: { draft.input }, set: { draft.editInput($0) })).focused($inputFocused).font(.system(size: 13)).frame(minHeight: 70, maxHeight: compact ? 100 : 150).scrollContentBackground(.hidden).padding(10).background(.background, in: RoundedRectangle(cornerRadius: 12))
                if !compact { HStack { Button(L("Use clipboard")) { store.useClipboardInput(draft) }; Button(L("Suggest CLI")) { store.generateCommandProposal(draft: draft) }; Button(L("Read-only agent")) { store.runReadOnlyAgent(draft: draft) }; Spacer() }.controlSize(.small) }
            }
            if compact && draft.input.isEmpty && task == nil { Text(L("No selected text. Enter text to begin.")).font(.caption).foregroundStyle(.secondary) }
            if let task {
                HStack { Text(task.state).font(.caption).foregroundStyle(.secondary); Spacer() }
                ScrollView {
                    Text(task.output.isEmpty && task.isRunning ? L("Waiting for response…") : task.output)
                        .font(.system(size: compact ? 13 : 14)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(12)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background.opacity(compact ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
            } else if !compact { KDEmptyState(symbol: "sparkles", title: L("Ready when you are"), detail: L("Choose an action and add text. Only this input is sent to your model.")) }
            if !draft.notice.isEmpty { KDInlineNotice(draft.notice).lineLimit(compact ? 2 : 4) }
            if compact && task == nil { Spacer(minLength: 0) }
            HStack(spacing: 12) {
                if let id = task?.id {
                    Button(L("Copy")) { store.copyResult(id) }.disabled(task?.output.isEmpty != false)
                    if store.canReplaceResult(id) { Button(L("Replace original selection")) { store.replaceResult(id) } }
                }
                if compact && store.configuration.endpoint.isEmpty { Button(L("Configure AI")) { store.onOpenSettings?(.aiService) } }
                Spacer()
                if compact { Button(L("Open in Workspace")) { store.onOpenWorkspace?(.ai(draft.id)) } }
                else { Button(L("Configure AI")) { store.onOpenSettings?(.aiService) } }
            }.controlSize(.small)
        }.padding(compact ? 22 : 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: draft.id) {
                guard compact && draft.input.isEmpty else { return }
                // 先让输入控件注册到窗口焦点树，再请求首响应者。
                await Task.yield()
                inputFocused = true
            }
    }
}
