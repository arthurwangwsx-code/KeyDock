import Foundation
import ExecutionCore

extension WorkbenchModel {
    /// 可选材料预算不足只拒绝捕获，不影响已接纳的实际任务。
    @discardableResult func beginTaskMaterialCapture(_ id: UUID, definition: RunDefinitionReference?, input: String?) -> TaskMaterialCapture? {
        guard !isDesktopReview else { return nil }
        guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing, taskMaterialFence.current.enabled,
              taskMaterialCaptures[id] == nil, let definition,
              tasks.contains(where: { $0.id == id && $0.runAttempt == nil && !$0.restoredFromReceipt }),
              executionReservations.contains(id) else { return nil }
        let extra = definition.kind == .workflow ? TaskMaterialCapture.checkpointReservation : 0
        guard makeSessionRoom(additionalBytes: extra),
              let capture = TaskMaterialCapture(runID: id, definition: definition, input: input, fence: taskMaterialFence) else { return nil }
        taskMaterialCaptures[id] = capture
        return capture
    }

    func applyTaskMaterialPermission() {
        guard !isDesktopReview else { return }
        let desired = configuration.taskMaterialRetentionEnabled && !taskMaterialPauseNeedsPersistence && !isShuttingDown
        guard taskMaterialFence.current.enabled != desired else { return }
        if desired { taskMaterialFence.setEnabled(true); taskMaterialGeneration = taskMaterialFence.current.generation }
        else { revokeTaskMaterialCaptures(disabling: true) }
    }

    func revokeTaskMaterialCaptures(disabling: Bool) {
        if disabling { taskMaterialFence.setEnabled(false) }
        else { taskMaterialFence.invalidateContent() }
        for capture in taskMaterialCaptures.values { capture.revoke() }
        taskMaterialCaptures.removeAll()
        invalidateTaskMaterialBuffers(includeLoadedReads: !disabling || isShuttingDown)
        if disabling, !isShuttingDown { scheduleTaskMaterialPermissionBarrier() }
    }

    /// UI接入前保持内部入口；停用落盘失败仍在本会话撤销，其他设置写入不会偷偷恢复许可。
    @discardableResult func setTaskMaterialRetention(_ enabled: Bool) -> Bool {
        guard !isDesktopReview else { desktopReviewUnavailable(); return false }
        guard !isShuttingDown else { return false }
        var next = configuration; next.taskMaterialRetentionEnabled = enabled
        if !enabled {
            taskMaterialPauseNeedsPersistence = true
            revokeTaskMaterialCaptures(disabling: true)
            configuration.taskMaterialRetentionEnabled = false
        }
        guard commitSettingsConfiguration(next) else { return false }
        taskMaterialPauseNeedsPersistence = false
        applyTaskMaterialPermission()
        return true
    }
}
