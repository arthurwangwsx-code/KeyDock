import SwiftUI
import KeyDockUI

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
