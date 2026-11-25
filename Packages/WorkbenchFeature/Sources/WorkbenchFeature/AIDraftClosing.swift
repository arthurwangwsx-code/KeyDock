import Foundation

@MainActor struct AIDraftCloseIntent: Identifiable {
    let id = UUID()
    let document: AIDraftDocument
    let revision: UUID
    let preview: String
    let sourceTitle: String
    init(document: AIDraftDocument) {
        self.document = document; revision = document.revision
        preview = String(document.input.prefix(160)); sourceTitle = document.inputSourceTitle
    }
    func isCurrent(in store: WorkbenchModel) -> Bool { store.ownsDraft(document) && !document.isClosing && document.revision == revision }
    func perform(in store: WorkbenchModel) async -> Bool {
        guard isCurrent(in:store) else { return false }
        return await store.closeDraftAndWait(document)
    }
}

extension WorkbenchModel {
    /// 显式关闭与隐藏窗口分离；调用者取消等待也不能跳过实际worker收口。
    @discardableResult public func closeDraftAndWait(_ draft: AIDraftDocument) async -> Bool {
        guard ownsDraft(draft), !draft.isClosing else { return false }
        draft.beginClosing()
        proposalRequests[draft.id] = nil
        let runs = Set(tasks.filter { $0.draftID == draft.id }.map(\.id))
        for id in runs { resultTargets[id] = nil }
        pendingCommandReviews.removeAll { runs.contains($0.id) }
        if latestAutoCopyRunID.map(runs.contains) == true { latestAutoCopyRunID = nil }
        let handles = taskHandles.filter { runs.contains($0.key) }
        for id in handles.keys { cancelTask(id) }
        for handle in handles.values { await handle.value }
        guard drafts[draft.id] === draft else { return draft.isDiscarded }
        // 结果与已打开的命令编辑稿是独立事实；此动作只释放当前输入文档。
        removeSessionObjects(tasks: [], drafts: [draft.id])
        return true
    }
}
