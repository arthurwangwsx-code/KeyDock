import AppKit
import SwiftUI
import MacAdapters
import KeyDockUI

public struct WorkspaceView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @State private var confirmClear = false
    public init(store: WorkbenchModel, session: WorkspaceSession) { self.store = store; self.session = session }
    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<WorkspaceSession.Page?>(get: { session.page }, set: { if let value = $0 { session.page = value } })) {
                Label(L("Tasks"), systemImage: "rectangle.stack").tag(WorkspaceSession.Page.tasks)
                Label(L("Saved content"), systemImage: "tray").tag(WorkspaceSession.Page.retainedTaskContent)
                Label(L("AI workspace"), systemImage: "sparkles").tag(WorkspaceSession.Page.ai)
                Label(L("Agent workspace"), systemImage: "person.crop.rectangle.stack").tag(WorkspaceSession.Page.agent)
                Label(L("Workflows"),systemImage:"point.3.connected.trianglepath.dotted").tag(WorkspaceSession.Page.workflows)
                Label(L("Usage insights"),systemImage:"chart.bar").tag(WorkspaceSession.Page.activity)
                Label(L("Tools"),systemImage:"wrench.and.screwdriver").tag(WorkspaceSession.Page.tools)
                Label(L("Clipboard history"), systemImage: "clipboard").tag(WorkspaceSession.Page.clipboard)
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if !store.workspaceNotice.isEmpty { KDInlineNotice(store.workspaceNotice) }
                Group {
                switch session.page {
                case .tasks: taskContent
                case .retainedTaskContent: TaskMaterialLibraryView(store: store, session: session)
                case .ai:
                    if let draft = session.draft {
                        ScrollView {
                            AIContentView(store: store, draft: draft).frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    else {
                        VStack { KDEmptyState(symbol: "sparkles", title: L("Ready when you are"), detail: L("Choose an action and add text. Only this input is sent to your model.")); Button(L("New AI task"), action: newAI).buttonStyle(.borderedProminent).padding(.bottom, 60) }
                    }
                case .clipboard: clipboardContent
                case .agent: AgentWorkspaceView(store:store,session:session)
                case .activity: ActivityView(store:store)
                case .workflows: WorkflowWorkspaceView(store:store,session:session)
                case .tools: ToolsWorkspaceView(store:store,session:session)
                }
                }
            }
        }.frame(minWidth: KDTokens.workspaceMinimumSize.width, minHeight: KDTokens.workspaceMinimumSize.height).environment(\.locale, KDLocalizer.locale)
            .background {
                if let presentation = session.taskMaterialPresentation { TaskMaterialSheetHost(store: store, session: session, presentation: presentation).id(presentation.id) }
                if let launch = session.workflowLaunch { WorkflowLaunchSheetHost(store: store, session: session, launch: launch).id(launch.id) }
                if let review = session.savedToolRemoval { SavedToolRemovalSheetHost(store: store, session: session, presentation: review).id(review.id) }
                if let presentation = session.attemptPreparation { AttemptPreparationSheetHost(store: store, session: session, presentation: presentation).id(presentation.id) }
                if let presentation = session.sourceRemoval {
                    SourceRemovalSheetHost(store: store, presentation: presentation, cancel: session.cancelSourceRemoval, didAppear: session.sourceRemovalDidAppear, didDismiss: session.sourceRemovalDidDismiss).id(presentation.id)
                }
            }
    }
    private func newAI() { session.createDraft(in: store) }
    private var taskContent: some View {
        let language = store.configuration.language
        return GeometryReader { viewport in
        HSplitView {
            List(selection: $session.selectedTaskID) {
                ForEach(store.tasks) { task in
                    TaskHistoryRow(task: task, language: language).tag(task.id)
                }
            }.listStyle(.inset).environment(\.defaultMinListRowHeight, 56)
                .transaction { $0.animation = nil }
                .frame(minWidth: 220, idealWidth: 245, maxWidth: 300)
            ScrollViewReader { detailScroll in
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let task = store.tasks.first(where: { $0.id == session.selectedTaskID }) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(task.displayTitle).font(.system(size: 20, weight: .semibold)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            Text(task.state).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        HStack {
                        if store.pendingCommandReviews.contains(where: { $0.id == task.id }) {
                            Button(L("Review command draft")) { store.presentCommandReview(task.id) }
                        }
                        if task.canCancel, store.agentRunDefinitions[task.id] != nil { Button(L("Pause")) { store.pauseAgent(task.id) } }
                        if task.canCancel { Button(L("Stop")) { store.cancelTask(task.id) } }
                        if !task.isRunning, task.runAttempt != nil { Button(L("Prepare new attempt")) { session.prepareAttempt(task.id, in: store) } }
                        if task.runAttempt != nil {
                            Menu(L("Task content")) {
                                Button(L("Review content to save…")) { session.prepareTaskMaterial(task.id, mode: .saveReview, in: store) }.disabled(!store.taskMaterialFence.current.enabled || store.taskMaterialClearing)
                                Button(L("View retained content…")) { session.prepareTaskMaterial(task.id, mode: .view, in: store) }
                                    .disabled(store.taskMaterialKey(task).flatMap { store.taskMaterialHandles[$0] } == nil || store.taskMaterialClearing)
                            }.menuStyle(.borderlessButton).fixedSize()
                        }
                        Spacer(minLength: 0)
                        if task.desktopWorkspaceResult == nil { KDIconButton("doc.on.doc", label: L("Copy")) { store.copyResult(task.id) }.disabled(task.output.isEmpty) }
                        }
                    }
                    if !task.notice.isEmpty { KDInlineNotice(task.notice) }
                    if task.runAttempt?.recoveryOf != nil {
                        Text(L("This is a new attempt. The previous result and recorded cost were kept.")).font(.caption).foregroundStyle(.secondary)
                    } else if !task.isRunning && task.runAttempt == nil && task.restoredFromReceipt {
                        Text(L("This history record has no saved definition reference and cannot be restarted here.")).font(.caption).foregroundStyle(.secondary)
                    }
                    if task.source != nil || task.receiptIsAI {
                        Text(L("Run input") + " · " + task.inputSourceTitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if store.isRemovedMCPSource(task.inputProvenance) { Text(L("This MCP source was removed. The imported text is kept as a snapshot.")).font(.caption).foregroundStyle(.secondary) }
                    }
                    AgentApprovalView(store:store,runID:task.id)
                    if let budget = task.runTokenBudget { RunTokenBudgetStatusView(snapshot: budget, language: store.configuration.language) }
                    else if task.agentRunContractFingerprint != nil { Text(L("No run token threshold was enabled for this run.")).font(.caption).foregroundStyle(.secondary) }
                    if let checkpoint = store.workflowCheckpoints[task.id] { Text(L("Step")+" \(checkpoint.stepIndex+1) · "+workflowPhaseTitle(checkpoint.phase)).font(.caption).foregroundStyle(.secondary) }
                    ForEach(store.pendingWorkflowInputs.filter{$0.runID == task.id}) { request in WorkflowInputView(store:store,request:request) }
                    if let summary = task.aiUsageSummary { AIUsageStatusView(summary: summary, language: store.configuration.language) }
                    if let code = task.exitCode { Text(L("Exit code") + ": \(code)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    if let result = task.desktopWorkspaceResult {
                        DesktopWorkspaceResultView(result: result, language: store.configuration.language, labels: task.desktopWorkspaceLabels)
                            .frame(height: max(160, min(500, viewport.size.height * 0.45)))
                    } else {
                    ReadOnlyTextPreview(text: task.output.isEmpty ? (task.restoredFromReceipt ? L("Session output is not restored here. Use Task content to view text you saved.") : L("No output")) : task.output,
                        accessibilityLabel: L("Task output"), monospaced: true)
                        .frame(maxWidth: .infinity).frame(height: max(160, min(500, viewport.size.height * 0.45)))
                        .modifier(KDReadingSurface())
                    }
                    HStack {
                        if task.desktopWorkspaceResult == nil { Button(L("Explain with AI")) {
                            let action = store.configuration.aiActions.first { $0.builtinKey == "Explain command output" } ?? store.configuration.aiActions.last
                            let draft = store.createDraft(actionID: action?.id, input: task.output, source: .commandOutput)
                            guard store.ownsDraft(draft) else { return }
                            session.draft = draft; session.page = .ai
                        }.disabled(task.output.isEmpty) }
                        Spacer()
                        Text(task.startedAt, style: .time).font(.caption).foregroundStyle(.tertiary)
                    }
                } else { KDEmptyState(symbol: "rectangle.stack", title: L("Your tasks stay here"), detail: L("Closing the launcher does not stop running tasks.")) }
            }.padding(24).frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height), alignment: .topLeading).id("task-detail-top")
            }.onChange(of: session.selectedTaskID) { _, _ in detailScroll.scrollTo("task-detail-top", anchor: .top) }
            }
        }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
    }
    private var clipboardContent: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L("Search clipboard history"), text: $session.clipboardQuery).textFieldStyle(.roundedBorder)
                if session.clipboard.isSearching { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Clear all"), role: .destructive) { confirmClear = true }
                KDIconButton("slider.horizontal.3", label: L("Clipboard privacy")) { store.onOpenSettings?(.clipboard) }
            }.padding(20)
            if !store.clipboardCaptureNotice.isEmpty { KDInlineNotice(store.clipboardCaptureNotice) }
            if !session.clipboard.notice.isEmpty { KDInlineNotice(session.clipboard.notice) }
            if session.clipboard.results.isEmpty && !session.clipboard.isSearching {
                KDEmptyState(symbol: "clipboard", title: L("No clipboard items"), detail: L("Recording is optional. Sensitive marked content is skipped."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.clipboard.results) { entry in
                            clipboardRow(entry)
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .onAppear { [store] in session.clipboard.connect(to: store.clipboardStore, onMutation: { [weak store] in store?.refreshClipboard() }) }
        .onDisappear { session.clipboard.disconnect() }
        .onReceive(store.$clipboardRevision.dropFirst()) { _ in session.clipboard.refresh() }
        .confirmationDialog(L("Delete all clipboard history?"), isPresented: $confirmClear) {
            Button(L("Clear all"), role: .destructive) { Task { await session.clipboard.clear() } }
        }
        .sheet(isPresented: Binding(get: { session.clipboard.previewedID != nil }, set: { if !$0 { session.clipboard.closePreview() } })) {
            ClipboardPreviewSheet(session: session.clipboard, writer: store.copyClipboardText)
        }
    }
    private func clipboardRow(_ entry: ClipboardPreview) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.pinned ? "pin.fill" : "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { Text(entry.preview).font(.system(size: 12)).lineLimit(4).textSelection(.enabled); Text(entry.createdAt, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary) }
            Spacer()
            Button(L("Preview")) { session.clipboard.preview(entry) }
            KDIconButton(entry.pinned ? "pin.slash" : "pin", label: entry.pinned ? L("Unpin item") : L("Pin item")) { Task { await session.clipboard.pin(entry) } }
            Button(L("Copy")) { Task { await session.clipboard.copy(entry, perform: store.copyClipboardText) } }
            KDIconButton("trash", label: L("Delete"), role: .destructive) { Task { await session.clipboard.delete(entry) } }
        }.padding(.horizontal, 20).padding(.vertical, 10).accessibilityElement(children: .contain)
    }

}

/// 语言是明确的值依赖；ForEach始终仅用任务UUID识别行，不用语言覆盖原生List的行身份。
private struct TaskHistoryRow: View {
    let task: RunningTaskItem
    let language: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: task.isRunning ? "circle.dotted" : (task.status == .completed || task.status == .handedOff ? "checkmark.circle" : (task.status == .draftReady ? "doc.text" : "exclamationmark.circle")))
                .foregroundStyle(task.isRunning ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(task.state).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if task.isRunning { ProgressView().controlSize(.mini) }
        }.frame(height: 36).padding(.vertical, 6)
    }
}

struct AIDraftMenuLabel: View {
    @ObservedObject var draft: AIDraftDocument
    let selected: Bool
    let language: String
    var body: some View {
        let title = draft.input.split(whereSeparator: \.isNewline).first.map { String($0.prefix(50)) } ?? L("Untitled draft")
        Label(title, systemImage: selected ? "checkmark" : "doc.text")
    }
}
