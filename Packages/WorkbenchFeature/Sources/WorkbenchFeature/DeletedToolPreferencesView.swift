import SwiftUI
import KeyDockUI

struct DeletedToolPreferencesView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var presentation: DeletedToolPreferencePresentation
    var body: some View {
        let review = presentation.review
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Clear preferences for deleted tools?")).font(.title2.bold())
            Text(L("Only shortcut, favorite, alias and recent preferences for missing snippets, URL actions, collections and workflows are cleared. Saved definitions, collection contents, tasks and history are kept.")).font(.callout).foregroundStyle(.secondary)
            if review.entries.isEmpty { Text(L("There are no deleted tool preferences to clear.")) }
            else {
                Text(L("Deleted tool preferences") + ": " + review.entries.count.formatted()).font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(review.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(entry.title).fontWeight(.medium); Spacer(); if let shortcut = entry.shortcut { KDKeycap(shortcut.display) } }
                                Text(entry.id).font(.caption.monospaced()).textSelection(.enabled)
                                HStack {
                                    if entry.favorite { Text(L("Favorite")) }
                                    if entry.alias { Text(L("Search alias")) }
                                    if entry.recent { Text(L("Recent actions")) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12)
                }.frame(maxHeight: 240).modifier(KDReadingSurface())
            }
            if !store.settingsNotice.isEmpty { KDInlineNotice(store.settingsNotice) }
            HStack {
                Button(L("Cancel")) { session.cancelDeletedToolPreferences(presentation.id) }.keyboardShortcut(.cancelAction)
                Button(L("Review again")) { session.refreshDeletedToolPreferences(presentation.id, in: store) }
                Spacer()
                Button(L("Clear preferences"), role: .destructive) { session.confirmDeletedToolPreferences(review.id, in: store) }.disabled(review.entries.isEmpty)
            }
        }.padding(24).frame(width: 560)
    }
}
