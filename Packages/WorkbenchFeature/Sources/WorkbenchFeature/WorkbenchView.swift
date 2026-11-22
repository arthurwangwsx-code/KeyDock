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
                Label(L("AI workspace"), systemImage: "sparkles").tag(WorkspaceSession.Page.ai)
                Label(L("Clipboard history"), systemImage: "clipboard").tag(WorkspaceSession.Page.clipboard)
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if !store.workspaceNotice.isEmpty { KDInlineNotice(store.workspaceNotice) }
                Group {
                switch session.page {
                case .tasks: taskContent
                case .ai:
                    if let draft = session.draft { AIContentView(store: store, draft: draft) }
                    else {
                        VStack { KDEmptyState(symbol: "sparkles", title: L("Ready when you are"), detail: L("Choose an action and add text. Only this input is sent to your model.")); Button(L("New AI task")) { session.draft = store.createDraft() }.buttonStyle(.borderedProminent).padding(.bottom, 60) }
                    }
                case .clipboard: clipboardContent
                }
                }
            }.navigationTitle(pageTitle)
                .toolbar { ToolbarItem { Button { store.onOpenSettings?(nil) } label: { Image(systemName: "gearshape") }.help(L("Settings")) } }
        }.frame(minWidth: 820, minHeight: 560).environment(\.locale, KDLocalizer.locale)
    }
    private var pageTitle: String { switch session.page { case .tasks: L("Tasks"); case .ai: L("AI workspace"); case .clipboard: L("Clipboard history") } }
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
                        if task.isRunning { Button(L("Stop")) { store.cancelTask(task.id) }.keyboardShortcut(".", modifiers: .command) }
                        KDIconButton("doc.on.doc", label: L("Copy")) { store.copyResult(task.id) }.disabled(task.output.isEmpty)
                    }
                    if !task.notice.isEmpty { KDInlineNotice(task.notice) }
                    if let code = task.exitCode { Text(L("Exit code") + ": \(code)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    ScrollView { Text(task.output.isEmpty ? (task.restoredFromReceipt ? L("Output is not retained after restarting KeyDock.") : L("No output")) : task.output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Button(L("Explain with AI")) {
                            let action = store.configuration.aiActions.first { $0.builtinKey == "Explain command output" } ?? store.configuration.aiActions.last
                            let draft = store.createDraft(actionID: action?.id, input: task.output, source: .commandOutput)
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
                Button { store.onOpenSettings?(.clipboard) } label: { Image(systemName: "slider.horizontal.3") }.help(L("Clipboard privacy"))
            }.padding(20)
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
            Button { Task { await session.clipboard.pin(entry) } } label: { Image(systemName: entry.pinned ? "pin.slash" : "pin") }.help(entry.pinned ? L("Unpin item") : L("Pin item")).accessibilityLabel(entry.pinned ? L("Unpin item") : L("Pin item"))
            Button(L("Copy")) { Task { await session.clipboard.copy(entry, perform: store.copyClipboardText) } }
            Button { Task { await session.clipboard.delete(entry) } } label: { Image(systemName: "trash") }.help(L("Delete"))
        }.padding(.horizontal, 20).padding(.vertical, 10).accessibilityElement(children: .contain)
    }

}
