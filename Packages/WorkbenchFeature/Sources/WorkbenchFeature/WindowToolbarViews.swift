import SwiftUI
import KeyDockUI
import ExecutionCore

/// 由AppKit工具栏承载；正文NavigationSplitView不再接管窗口工具栏或安全区。
public struct WorkspaceToolbarView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    public init(store: WorkbenchModel, session: WorkspaceSession) { self.store = store; self.session = session }
    public var body: some View {
        HStack(spacing: 12) {
            if session.page == .ai {
                KDIconButton("square.and.pencil", label: L("New AI task"), style: .toolbar) { session.createDraft(in: store) }
                Menu {
                    ForEach(session.availableDrafts(in: store)) { draft in
                        Button { session.navigate(.ai(draft.id), store: store) } label: { AIDraftMenuLabel(draft: draft, selected: session.draft?.id == draft.id) }
                    }
                } label: { Image(systemName: "clock") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(L("AI drafts")).help(L("Drafts kept for this session"))
                    .disabled(session.availableDrafts(in: store).isEmpty)
            }
            KDIconButton("gearshape", label: L("Settings"), style: .toolbar) { store.onOpenSettings?(nil) }
        }.buttonStyle(.borderless).frame(width: 160, height: 32, alignment: .trailing).environment(\.locale, KDLocalizer.locale)
    }
}

public struct SettingsToolbarView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    public init(store: WorkbenchModel, session: SettingsSession) { self.store = store; self.session = session }
    public var body: some View {
        Group {
            if session.pane == .commands {
                KDIconButton("plus", label: L("New command"), style: .toolbar) { session.editedCommandSourceRunID = nil; session.editedCommand = SavedCommand(name: "", executable: "/usr/bin/printf") }
            } else if session.pane == .aiActions {
                KDIconButton("plus", label: L("New action"), style: .toolbar) { session.editedAction = AIActionPreset(name: "", prompt: "") }
            }
        }.buttonStyle(.borderless).frame(width: 40, height: 32).environment(\.locale, KDLocalizer.locale)
    }
}
