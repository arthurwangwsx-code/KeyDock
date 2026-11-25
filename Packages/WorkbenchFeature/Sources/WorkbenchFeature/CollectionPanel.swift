import SwiftUI
import CommandCore

// Form会展开多个动态列表；浏览与编辑即使引用同一动作也不能共享行身份。
private struct CollectionPresentationRow: Identifiable {
    enum Scope: Hashable { case saved(UUID), draft }
    struct ID: Hashable { let scope: Scope; let commandID: String }
    let id: ID
    let index: Int
    var commandID: String { id.commandID }
    static func rows(_ values: [String], scope: Scope) -> [Self] {
        values.enumerated().map { Self(id: ID(scope: scope, commandID: $0.element), index: $0.offset) }
    }
}

struct CollectionPanel: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    var onRemove: (UUID) -> Void

    private var candidates: [CommandItem] {
        store.collectionActions.filter { session.collectionDraft.actionFilter.isEmpty || $0.title.localizedCaseInsensitiveContains(session.collectionDraft.actionFilter) }
    }
    var body: some View {
        Section(L("Command collections")) {
            Text(L("Group related actions into a named workspace. Each action runs only when selected; opening a collection does not run every command.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Collection"), selection: $session.selectedCollectionID) {
                Text(L("Choose a collection")).tag(Optional<UUID>.none)
                ForEach(store.configuration.collections) { Text($0.name).tag(Optional($0.id)) }
            }
            .onAppear { session.reconcileCollectionSelection(in: store) }
            .onChange(of: store.configuration.collections.map(\.id)) { _, _ in session.reconcileCollectionSelection(in: store) }
            if let collection = store.configuration.collections.first(where: { $0.id == session.selectedCollectionID }) {
                HStack {
                    Text(collection.name).font(.headline); Spacer()
                    Button(L("Edit")) { session.editCollection(collection) }
                    Button(L("Remove collection"), role: .destructive) { onRemove(collection.id) }
                }
                ForEach(CollectionPresentationRow.rows(collection.commandIDs, scope: .saved(collection.id))) { row in
                    let index = row.index, id = row.commandID
                    HStack {
                        Text((index + 1).formatted()).monospacedDigit().foregroundStyle(.secondary)
                        Text(store.collectionAction(id)?.title ?? L("Unavailable action")).lineLimit(1); Spacer()
                        Button(store.collectionAction(id)?.kind == .ai ? L("Open AI workspace") : L("Run")) { store.runCollectionAction(id) }
                            .disabled(!store.isCollectionActionEnabled(id))
                            .accessibilityLabel((store.collectionAction(id)?.kind == .ai ? L("Open AI workspace") : L("Run")) + ": " + (store.collectionAction(id)?.title ?? L("Unavailable action")))
                    }
                }
            }
            Text(session.collectionDraft.editingID == nil ? L("New collection") : L("Editing collection")).font(.headline)
            TextField(L("Collection name"), text: $session.collectionDraft.name)
            Text(L("Action order")).font(.subheadline)
            if session.collectionDraft.commandIDs.isEmpty { Text(L("Choose actions to build an ordered list.")).font(.caption).foregroundStyle(.secondary) }
            ForEach(CollectionPresentationRow.rows(session.collectionDraft.commandIDs, scope: .draft)) { row in
                let index = row.index, id = row.commandID
                let action = store.collectionAction(id)
                let title = action?.title ?? L("Unavailable action")
                HStack {
                    Text((index + 1).formatted()).monospacedDigit().foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).lineLimit(1)
                        if action == nil { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                    }
                    Spacer()
                    Button { session.collectionDraft.move(id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help(L("Move earlier")).accessibilityLabel(L("Move earlier") + ": " + (index + 1).formatted() + ", " + title)
                    Button { session.collectionDraft.move(id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == session.collectionDraft.commandIDs.count - 1).help(L("Move later")).accessibilityLabel(L("Move later") + ": " + (index + 1).formatted() + ", " + title)
                    Button { session.collectionDraft.select(id, selected: false) } label: { Image(systemName: "minus.circle") }
                        .help(L("Remove")).accessibilityLabel(L("Remove") + ": " + (index + 1).formatted() + ", " + title)
                }.buttonStyle(.borderless)
            }
            Button(L("Remove unavailable actions")) { session.collectionDraft.removeUnavailable(availableIDs: Set(store.collectionActions.map(\.id))) }
            TextField(L("Find an action"), text: $session.collectionDraft.actionFilter)
            Text(L("Window actions need the original target. Use the launcher or a direct shortcut.")).font(.caption).foregroundStyle(.secondary)
            Text(L("AI actions open a blank draft. Choose input and run it in AI workspace.")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L("Choose actions"), isExpanded: $session.collectionDraft.choosingActions) {
                ForEach(Array(candidates.prefix(80))) { item in
                    Toggle(item.title, isOn: Binding(get: { session.collectionDraft.commandIDs.contains(item.id) }, set: { session.selectCollectionAction(item.id, selected: $0, in: store) }))
                }
                if candidates.isEmpty { Text(L("No matching actions")).font(.caption).foregroundStyle(.secondary) }
                if candidates.count > 80 { Text(L("Refine your search to see more actions.")).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button(L("Save collection")) { session.saveCollection(in: store) }
                Button(L("New collection")) { session.newCollection() }
            }
        }
    }
}
