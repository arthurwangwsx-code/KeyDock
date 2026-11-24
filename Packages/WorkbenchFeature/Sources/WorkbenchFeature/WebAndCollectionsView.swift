import SwiftUI
import CommandCore

struct WebAndCollectionsPanel: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @State private var removal: String?
    var body: some View {
        Section(L("URL actions")) {
            ForEach(store.configuration.webActions) { item in
                HStack {
                    Text(item.name).lineLimit(1); Spacer()
                    Button(L("Use")) { session.selectedWebActionID = item.id }
                    Button(L("Edit")) { session.editWebAction(item) }
                    Button(L("Remove"),role:.destructive) { removal = "web."+item.id.uuidString }
                }
            }
            if let item = store.configuration.webActions.first(where:{$0.id == session.selectedWebActionID}) {
                Text(item.name).font(.headline)
                if item.requiresQuery { TextField(L("Search query"),text:$session.webQuery).onSubmit { open(item) } }
                if let destination = try? item.resolvedURL(query:item.requiresQuery ? session.webQuery:nil) { Text(destination.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button(L("Open URL")) { open(item) }.disabled(item.requiresQuery && session.webQuery.isEmpty)
            }
            Text(session.webActionDraft.editingID == nil ? L("New URL action") : L("Editing URL action")).font(.headline)
            TextField(L("Name"),text:$session.webActionDraft.name)
            TextField(L("URL or template"),text:$session.webActionDraft.urlTemplate)
            Text(L("Example: https://example.com/search?q={query}. Query text is percent-encoded; scripts and custom URL schemes are rejected.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Save URL action")) { session.saveWebAction(in: store) }
                Button(L("New URL action")) { session.newWebAction() }
            }
        }
        CollectionPanel(store: store, session: session) { removal = "collection." + $0.uuidString }
            .confirmationDialog(L("Remove this saved item?"),isPresented:Binding(get:{removal != nil},set:{if !$0 { removal = nil }})) {
                Button(L("Remove"),role:.destructive) {
                    if let value = removal,let id = UUID(uuidString:String(value.split(separator:".").last ?? "")) { if value.hasPrefix("web.") { store.removeWebAction(id) } else { store.removeCollection(id) } }; removal = nil
                }
            }
    }
    private func open(_ item:WebActionDefinition) { store.openWebAction(item.id,query:item.requiresQuery ? session.webQuery:nil) }
}
