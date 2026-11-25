import SwiftUI
import KeyDockUI

struct SavedItemRemovalView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var presentation: SavedItemRemovalPresentation
    var body: some View {
        SavedItemRemovalContent(presentation: presentation, notice: store.settingsNotice,
            cancel: { session.cancelRemoval($0) }, refresh: { session.refreshRemoval($0, in: store) }, confirm: { session.confirmRemoval($0, in: store) })
    }
}

struct SavedToolRemovalView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var presentation: SavedItemRemovalPresentation
    var body: some View {
        SavedItemRemovalContent(presentation: presentation, notice: store.workspaceNotice,
            cancel: { session.cancelToolRemoval($0) }, refresh: { session.refreshToolRemoval($0, in: store) }, confirm: { session.confirmToolRemoval($0, in: store) })
    }
}

private struct SavedItemRemovalContent: View {
    @ObservedObject var presentation: SavedItemRemovalPresentation
    let notice: String
    let cancel: (UUID) -> Void
    let refresh: (UUID) -> Void
    let confirm: (UUID) -> Bool
    var body: some View {
        let review = presentation.review
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Remove saved item?")).font(.title2.bold())
            Text(review.name).font(.headline).textSelection(.enabled)
            Text(L("This removes its shortcut, favorite and alias. Running tasks and history keep their original data.")).font(.callout).foregroundStyle(.secondary)
            if !review.dependencies.isEmpty {
                Text(L("This item is still in use. Remove its references, then review again.")).font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(review.dependencies) { dependency in Text(dependency.title).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(12)
                }.frame(maxHeight: 180).modifier(KDReadingSurface())
            }
            if !notice.isEmpty { KDInlineNotice(notice) }
            HStack {
                Button(L("Cancel")) { cancel(presentation.id) }.keyboardShortcut(.cancelAction)
                Button(L("Review again")) { refresh(presentation.id) }
                    .accessibilityLabel(L("Review again") + " · " + review.name)
                Spacer()
                Button(L("Remove"), role: .destructive) { _ = confirm(review.id) }.disabled(!review.dependencies.isEmpty)
                    .accessibilityLabel(L("Remove") + " · " + review.name)
            }
        }.padding(24).frame(width: 520)
    }
}
