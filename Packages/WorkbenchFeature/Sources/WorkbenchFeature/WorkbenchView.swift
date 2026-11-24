import AppKit
import SwiftUI
import MacAdapters
import KeyDockUI

public struct WorkspaceView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @State private var confirmClear = false
    @State private var restartID: UUID?
    public init(store: WorkbenchModel, session: WorkspaceSession) { self.store = store; self.session = session }
    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<WorkspaceSession.Page?>(get: { session.page }, set: { if let value = $0 { session.page = value } })) {
                Label(L("Tasks"), systemImage: "rectangle.stack").tag(WorkspaceSession.Page.tasks)
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
        }.frame(minWidth: 820, minHeight: 560).environment(\.locale, KDLocalizer.locale)
            .sheet(item: $session.workflowLaunch) { launch in WorkflowLaunchView(store: store, session: session, launch: launch) }
            .confirmationDialog(L("Start a new attempt?"),isPresented:Binding(get:{restartID != nil},set:{if !$0 {restartID = nil}})) {
                Button(L("Start new attempt")) { if let id = restartID { store.restartAgent(id) }; restartID = nil }
            } message: { Text(L("A new attempt rechecks current scope and may repeat completed work. Unknown effects must be checked first.")) }
    }
    private func newAI() { session.createDraft(in: store) }
    private var taskContent: some View {
        HSplitView {
            List(selection: $session.selectedTaskID) {
                ForEach(store.tasks) { task in
                    HStack(spacing: 9) {
                        Image(systemName: task.isRunning ? "circle.dotted" : (task.status == .completed || task.status == .handedOff ? "checkmark.circle" : "exclamationmark.circle")).foregroundStyle(task.isRunning ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) { Text(task.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(task.state).font(.system(size: 10)).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        if task.isRunning { ProgressView().controlSize(.mini) }
                    }.padding(.vertical, 6).tag(task.id)
                }
            }.listStyle(.inset).frame(minWidth: 220, idealWidth: 245, maxWidth: 300)
            VStack(alignment: .leading, spacing: 18) {
                if let task = store.tasks.first(where: { $0.id == session.selectedTaskID }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) { Text(task.displayTitle).font(.system(size: 20, weight: .semibold)); Text(task.state).font(.system(size: 12)).foregroundStyle(.secondary) }
                        Spacer()
                        if task.canCancel, store.agentRunDefinitions[task.id] != nil { Button(L("Pause")) { store.pauseAgent(task.id) } }
                        if task.canCancel { Button(L("Stop")) { store.cancelTask(task.id) } }
                        if !task.isRunning, store.agentRunDefinitions[task.id] != nil, let draftID = task.draftID, store.drafts[draftID] != nil { Button(L("Start new attempt")) { restartID = task.id } }
                        KDIconButton("doc.on.doc", label: L("Copy")) { store.copyResult(task.id) }.disabled(task.output.isEmpty)
                    }
                    if !task.notice.isEmpty { KDInlineNotice(task.notice) }
                    AgentApprovalView(store:store,runID:task.id)
                    if let checkpoint = store.workflowCheckpoints[task.id] { Text(L("Step")+" \(checkpoint.stepIndex+1) · "+workflowPhaseTitle(checkpoint.phase)).font(.caption).foregroundStyle(.secondary) }
                    ForEach(store.pendingWorkflowInputs.filter{$0.runID == task.id}) { request in WorkflowInputView(store:store,request:request) }
                    if let summary = task.aiUsageSummary { AIUsageStatusView(summary: summary) }
                    if let code = task.exitCode { Text(L("Exit code") + ": \(code)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    ScrollView { Text(task.output.isEmpty ? (task.restoredFromReceipt ? L("Output is not retained after restarting KeyDock.") : L("No output")) : task.output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                        .modifier(KDReadingSurface())
                    HStack {
                        Button(L("Explain with AI")) {
                            let action = store.configuration.aiActions.first { $0.builtinKey == "Explain command output" } ?? store.configuration.aiActions.last
                            let draft = store.createDraft(actionID: action?.id, input: task.output, source: .commandOutput)
                            guard store.ownsDraft(draft) else { return }
                            session.draft = draft; session.page = .ai
                        }.disabled(task.output.isEmpty)
                        Spacer()
                        Text(task.startedAt, style: .time).font(.caption).foregroundStyle(.tertiary)
                    }
                } else { KDEmptyState(symbol: "rectangle.stack", title: L("Your tasks stay here"), detail: L("Closing the launcher does not stop running tasks.")) }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct AIDraftMenuLabel: View {
    @ObservedObject var draft: AIDraftDocument
    let selected: Bool
    var body: some View {
        let title = draft.input.split(whereSeparator: \.isNewline).first.map { String($0.prefix(50)) } ?? L("Untitled draft")
        Label(title, systemImage: selected ? "checkmark" : "doc.text")
    }
}
