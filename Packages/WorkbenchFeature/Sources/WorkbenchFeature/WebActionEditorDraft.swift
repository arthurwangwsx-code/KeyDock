import Foundation
import CommandCore

/// 编辑身份与运行目标分离；未完成的字段只属于当前窗口会话。
struct WebActionEditorDraft: Equatable {
    var editingID: UUID? = nil
    var expectedFingerprint: String? = nil
    var name = ""
    var urlTemplate = ""
}

extension WorkspaceSession {
    func editWebAction(_ action: WebActionDefinition) {
        guard savedToolRemoval == nil else { return }
        webActionDraft = WebActionEditorDraft(editingID: action.id, expectedFingerprint: SavedItemIdentity.fingerprint(action), name: action.name, urlTemplate: action.urlTemplate)
    }
    func newWebAction() { guard savedToolRemoval == nil else { return }; webActionDraft = WebActionEditorDraft() }
    @discardableResult func saveWebAction(in store: WorkbenchModel) -> Bool {
        guard savedToolRemoval == nil else { return false }
        let draft = webActionDraft
        if let id = draft.editingID, !store.validateSavedToolEdit(.webAction(id), expected: draft.expectedFingerprint) { return false }
        guard store.saveWebAction(id: draft.editingID, name: draft.name, template: draft.urlTemplate) else { return false }
        newWebAction()
        return true
    }
}
