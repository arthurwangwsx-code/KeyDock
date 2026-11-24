import Foundation
import CommandCore

/// 编辑身份与运行目标分离；未完成的字段只属于当前窗口会话。
struct WebActionEditorDraft: Equatable {
    var editingID: UUID? = nil
    var name = ""
    var urlTemplate = ""
}

extension WorkspaceSession {
    func editWebAction(_ action: WebActionDefinition) {
        webActionDraft = WebActionEditorDraft(editingID: action.id, name: action.name, urlTemplate: action.urlTemplate)
    }
    func newWebAction() { webActionDraft = WebActionEditorDraft() }
    @discardableResult func saveWebAction(in store: WorkbenchModel) -> Bool {
        let draft = webActionDraft
        guard store.saveWebAction(id: draft.editingID, name: draft.name, template: draft.urlTemplate) else { return false }
        newWebAction()
        return true
    }
}
