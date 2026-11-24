import SwiftUI
import CommandCore

struct WebAndCollectionsPanel: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @State private var webName = ""
    @State private var webTemplate = ""
    @State private var collectionName = ""
    @State private var selected: Set<String> = []
    @State private var actionFilter = ""
    @State private var removal: String?
    var body: some View {
        Section(L("URL actions")) {
            ForEach(store.configuration.webActions) { item in
                HStack {
                    Text(item.name).lineLimit(1); Spacer()
                    Button(L("Use")) { session.selectedWebActionID = item.id }
                    Button(L("Edit")) { session.selectedWebActionID = item.id; webName = item.name; webTemplate = item.urlTemplate }
                    Button(L("Remove"),role:.destructive) { removal = "web."+item.id.uuidString }
                }
            }
            if let item = store.configuration.webActions.first(where:{$0.id == session.selectedWebActionID}) {
                Text(item.name).font(.headline)
                if item.requiresQuery { TextField(L("Search query"),text:$session.webQuery).onSubmit { open(item) } }
                if let destination = try? item.resolvedURL(query:item.requiresQuery ? session.webQuery:nil) { Text(destination.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button(L("Open URL")) { open(item) }.disabled(item.requiresQuery && session.webQuery.isEmpty)
            }
            TextField(L("Name"),text:$webName)
            TextField(L("URL or template"),text:$webTemplate)
            Text(L("Example: https://example.com/search?q={query}. Query text is percent-encoded; scripts and custom URL schemes are rejected.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Save URL action")) { if store.saveWebAction(id:session.selectedWebActionID,name:webName,template:webTemplate) { webName = ""; webTemplate = "" } }
                Button(L("New URL action")) { session.selectedWebActionID = nil; webName = ""; webTemplate = ""; session.webQuery = "" }
            }
        }
        Section(L("Command collections")) {
            Text(L("Group related actions into a named workspace. Each action runs only when selected; opening a collection does not run every command.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Collection"),selection:$session.selectedCollectionID) {
                Text(L("New collection")).tag(Optional<UUID>.none)
                ForEach(store.configuration.collections) { Text($0.name).tag(Optional($0.id)) }
            }.onChange(of:session.selectedCollectionID) { _,value in
                let collection = store.configuration.collections.first{$0.id == value}; collectionName = collection?.name ?? ""; selected = Set(collection?.commandIDs ?? [])
            }
            if let collection = store.configuration.collections.first(where:{$0.id == session.selectedCollectionID}) {
                ForEach(collection.commandIDs,id:\.self) { id in
                    HStack {
                        Text(store.catalog.first{$0.id == id}?.title ?? L("Unavailable action")).lineLimit(1); Spacer()
                        Button(L("Run")) { if let item = store.catalog.first(where:{$0.id == id}) { store.execute(item) } }.disabled(!store.catalog.contains{$0.id == id})
                    }
                }
                Button(L("Remove collection"),role:.destructive) { removal = "collection."+collection.id.uuidString }
            }
            TextField(L("Collection name"),text:$collectionName)
            TextField(L("Find an action"),text:$actionFilter)
            Button(L("Remove unavailable actions")) { selected = selected.filter { id in store.catalog.contains{$0.id == id} } }
            DisclosureGroup(L("Choose actions")) {
                ForEach(Array(store.catalog.filter{$0.kind != .window && !$0.id.hasPrefix("collection.") && (actionFilter.isEmpty || $0.title.localizedCaseInsensitiveContains(actionFilter))}.prefix(80))) { item in
                    Toggle(item.title,isOn:Binding(get:{selected.contains(item.id)},set:{value in if value { if selected.count < 32 { selected.insert(item.id) } } else { selected.remove(item.id) } }))
                }
            }
            Button(L("Save collection")) {
                let id = session.selectedCollectionID ?? UUID()
                if store.saveCollection(id:id,name:collectionName,commandIDs:selected.sorted()) { session.selectedCollectionID = id }
            }
        }.onAppear { if let collection = store.configuration.collections.first(where:{$0.id == session.selectedCollectionID}) { collectionName = collection.name; selected = Set(collection.commandIDs) } }
            .confirmationDialog(L("Remove this saved item?"),isPresented:Binding(get:{removal != nil},set:{if !$0 { removal = nil }})) {
                Button(L("Remove"),role:.destructive) {
                    if let value = removal,let id = UUID(uuidString:String(value.split(separator:".").last ?? "")) { if value.hasPrefix("web.") { store.removeWebAction(id) } else { store.removeCollection(id) } }; removal = nil
                }
            }
    }
    private func open(_ item:WebActionDefinition) { store.openWebAction(item.id,query:item.requiresQuery ? session.webQuery:nil) }
}
