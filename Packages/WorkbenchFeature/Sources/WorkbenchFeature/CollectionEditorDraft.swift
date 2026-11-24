import Foundation
import CommandCore

/// 浏览选择独立于编辑身份；数组保留用户顺序，过滤不改变清单。
struct CollectionEditorDraft: Equatable {
    var editingID: UUID? = nil
    var name = ""
    var commandIDs: [String] = []
    var actionFilter = ""
    var choosingActions = false

    @discardableResult mutating func select(_ id: String, selected: Bool) -> Bool {
        if !selected { commandIDs.removeAll { $0 == id }; return true }
        if commandIDs.contains(id) { return true }
        guard commandIDs.count < 32 else { return false }
        commandIDs.append(id)
        return true
    }
    @discardableResult mutating func move(_ id: String, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1, let index = commandIDs.firstIndex(of: id), commandIDs.indices.contains(index + offset) else { return false }
        commandIDs.swapAt(index, index + offset)
        return true
    }
    mutating func removeUnavailable(availableIDs: Set<String>) {
        commandIDs.removeAll { !availableIDs.contains($0) }
    }
}

extension WorkspaceSession {
    func editCollection(_ collection: CommandCollection) {
        collectionDraft = CollectionEditorDraft(editingID: collection.id, name: collection.name, commandIDs: collection.commandIDs)
    }
    func newCollection() { collectionDraft = CollectionEditorDraft() }
    func reconcileCollectionSelection(in store: WorkbenchModel) {
        if let id = selectedCollectionID, !store.configuration.collections.contains(where: { $0.id == id }) { selectedCollectionID = nil }
    }
    func selectCollectionAction(_ id: String, selected: Bool, in store: WorkbenchModel) {
        guard !selected || store.collectionAction(id) != nil else { return }
        if !collectionDraft.select(id, selected: selected) {
            store.workspaceNoticeMessage = noticeKey("A collection can contain up to 32 actions.")
        }
    }
    @discardableResult func saveCollection(in store: WorkbenchModel) -> Bool {
        let draft = collectionDraft
        guard store.saveCollection(id: draft.editingID, name: draft.name, commandIDs: draft.commandIDs) else { return false }
        newCollection()
        return true
    }
}
