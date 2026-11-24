import SwiftUI
import KeyDockUI

struct SavedItemRemovalView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var presentation: SavedItemRemovalPresentation
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
            if !store.settingsNotice.isEmpty { KDInlineNotice(store.settingsNotice) }
            HStack {
                Button(L("Cancel")) { session.cancelRemoval(presentation.id) }.keyboardShortcut(.cancelAction)
                Button(L("Review again")) { session.refreshRemoval(presentation.id, in: store) }
                Spacer()
                Button(L("Remove"), role: .destructive) { session.confirmRemoval(review.id, in: store) }.disabled(!review.dependencies.isEmpty)
            }
        }.padding(24).frame(width: 520)
    }
}
