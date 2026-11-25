import Foundation

extension SettingsSession {
    @discardableResult func saveMCPDraft(_ submitted: MCPServerDraft? = nil, in store: WorkbenchModel, trusted: Bool) async -> Bool {
        let draft = submitted ?? mcpDraft, epoch = mcpDraftEpoch
        guard sourceRemoval == nil, !sourceRemovalDismissing, draft.matchesSubmission(mcpDraft), !store.isShuttingDown else {
            store.settingsNoticeMessage = noticeKey("The server draft changed. Review the current configuration before saving."); return false
        }
        guard let saved = await store.saveMCPServerResult(draft, trusted: trusted) else { return false }
        // 回调仅更新原提交稿；新稿或其间输入的key不被旧成功清掉。
        if mcpDraftEpoch == epoch, mcpDraft.presentationID == draft.presentationID, mcpDraft.editingRevision == draft.editingRevision {
            mcpDraft.editingRevision = saved.revision
            if mcpDraft.apiKey.utf8.elementsEqual(draft.apiKey.utf8) { mcpDraft.apiKey = "" }
        }
        return true
    }
}
