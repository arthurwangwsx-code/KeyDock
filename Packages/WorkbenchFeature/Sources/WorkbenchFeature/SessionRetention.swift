import Foundation
import ExecutionCore
import MacAdapters

public struct SessionRetentionPolicy: Sendable {
    public let activeTasks: Int
    public let tasks: Int
    public let drafts: Int
    public let textBytes: Int
    public init(activeTasks: Int = 8, tasks: Int = 200, drafts: Int = 32, textBytes: Int = 33_554_432) {
        self.activeTasks = max(1, activeTasks); self.tasks = max(1, tasks)
        self.drafts = max(1, drafts); self.textBytes = max(1, textBytes)
    }
}

public struct PendingCommandReview: Identifiable {
    public let id: UUID
    public let command: SavedCommand
    let textBytes: Int
}

enum SessionAdmissionError: Error { case capacity }

extension WorkbenchModel {
    public func ownsDraft(_ draft: AIDraftDocument) -> Bool { !draft.isDiscarded && drafts[draft.id] === draft }

    public func setVisibleReferences(owner: UUID, draftID: UUID?, taskID: UUID?) {
        visibleDraftReferences[owner] = draftID; visibleTaskReferences[owner] = taskID
    }
    public func releaseVisibleReferences(owner: UUID) {
        visibleDraftReferences[owner] = nil; visibleTaskReferences[owner] = nil
    }
    var protectedDraftIDs: Set<UUID> {
        // 未审阅提案的原输入也保留；不能因逐出任务而静默丢失待审内容。
        let reviewRuns = Set(pendingCommandReviews.map(\.id)).union(activeCommandReviews.keys)
        return Set(visibleDraftReferences.values).union(tasks.filter { executionReservations.contains($0.id) || reviewRuns.contains($0.id) }.compactMap(\.draftID))
    }
    var protectedTaskIDs: Set<UUID> {
        let visibleRuns = visibleDraftReferences.values.compactMap { drafts[$0]?.latestRunID }
        return Set(visibleTaskReferences.values).union(visibleRuns).union(executionReservations)
            .union(pendingCommandReviews.map(\.id)).union(activeCommandReviews.keys)
    }

    /// 整份输出在任何Published更新/窗口回调之前预留，避免同步重入绕过并发上限。
    func reserveExecution(_ id: UUID, draft: AIDraftDocument? = nil, additionalBytes: Int = 0) -> Bool {
        guard !isShuttingDown, !isClearingHistory, !mutatingSession,
              executionReservations.count < sessionLimits.activeTasks else { admissionNotice(draft); return false }
        executionReservations.insert(id)
        guard makeSessionRoom(taskSlots: 1, additionalBytes: additionalBytes, protectingDraft: draft?.id) else {
            executionReservations.remove(id); admissionNotice(draft); return false
        }
        return true
    }
    func finishExecutionReservation(_ id: UUID, owner: InvocationWorkerOwnership? = nil) {
        taskHandles[id] = nil; executionReservations.remove(id)
        aiTaskIDs.remove(id); cancelledTaskIDs.remove(id)
        timedOutTaskIDs.remove(id); pausedAgentIDs.remove(id)
        let cli = invocationStore, ai = aiInvocationStore
        Task { [weak self] in
            if let owner { await owner.release() }
            else { await cli.releaseProtection(for: id); await ai.releaseProtection(for: id) }
            guard let self, !self.isShuttingDown else { return }
            await self.maintainTaskHistory()
        }
    }
    func admissionNotice(_ draft: AIDraftDocument? = nil) {
        let message = isClearingHistory ? noticeKey("History is being cleared. Try again when it finishes.") : noticeKey("KeyDock is at its task or text limit. Finish a task or clear older history, then try again.")
        draft?.noticeMessage = message; launcherNoticeMessage = message; workspaceNoticeMessage = message
    }

    /// 返回完整逐出计划后才修改会话，拒收时不先删除一部分历史。
    func makeSessionRoom(taskSlots: Int = 0, draftSlots: Int = 0, additionalBytes: Int = 0, protectingDraft: UUID? = nil) -> Bool {
        guard !mutatingSession else { return false }
        var removedTasks: Set<UUID> = [], removedDrafts: Set<UUID> = []
        let safeTasks = tasks.filter { $0.finishedAt != nil && !protectedTaskIDs.contains($0.id) }.sorted { $0.startedAt < $1.startedAt }
        var safeDrafts = draftOrder.filter { !protectedDraftIDs.contains($0) && $0 != protectingDraft }
        var taskIndex = 0
        func fits() -> Bool {
            tasks.count - removedTasks.count + taskSlots <= sessionLimits.tasks &&
            drafts.count - removedDrafts.count + draftSlots <= sessionLimits.drafts &&
            retainedSessionBytes(excludingTasks: removedTasks, excludingDrafts: removedDrafts) + additionalBytes <= sessionLimits.textBytes
        }
        while !fits() {
            if drafts.count - removedDrafts.count + draftSlots > sessionLimits.drafts {
                guard !safeDrafts.isEmpty else { return false }
                removedDrafts.insert(safeDrafts.removeFirst())
            } else if tasks.count - removedTasks.count + taskSlots > sessionLimits.tasks {
                guard taskIndex < safeTasks.count else { return false }
                removedTasks.insert(safeTasks[taskIndex].id); taskIndex += 1
            } else if taskIndex < safeTasks.count {
                removedTasks.insert(safeTasks[taskIndex].id); taskIndex += 1
            } else if !safeDrafts.isEmpty { removedDrafts.insert(safeDrafts.removeFirst()) }
            else { return false }
        }
        removeSessionObjects(tasks: removedTasks, drafts: removedDrafts)
        return true
    }

    func retainedSessionBytes(excludingTasks taskIDs: Set<UUID> = [], excludingDrafts draftIDs: Set<UUID> = []) -> Int {
        // 为下一次面板上下文预留一个固定槽位，捕获完成不会绕过全局预算。
        var bytes = TaskTextLimits.inputBytes + 1_024 + retainedContextSlotBytes, snapshots: [ObjectIdentifier: TargetSnapshot] = [:]
        func include(_ snapshot: TargetSnapshot?) { if let snapshot { snapshots[ObjectIdentifier(snapshot)] = snapshot } }
        for task in tasks where !taskIDs.contains(task.id) {
            let metadata = (task.inputProvenance?.retainedBytes ?? 0) + task.title.utf8.count + task.noticeMessage.retainedByteCount + (task.modelName?.utf8.count ?? 0) + (task.sourceApplication?.utf8.count ?? 0) + task.desktopWorkspaceLabels.values.reduce(0) { $0 + $1.utf8.count } + (task.desktopWorkspaceResult == nil ? 0 : 4_096)
            bytes += task.output.utf8.count + metadata
            if executionReservations.contains(task.id) {
                bytes += max(0, TaskTextLimits.outputBytes - task.output.utf8.count) + max(0, 16_384 - metadata) + TaskTextLimits.inputBytes
            }
            include(resultTargets[task.id])
        }
        let existingIDs = Set(tasks.map(\.id))
        bytes += executionReservations.subtracting(existingIDs).count * (TaskTextLimits.outputBytes + 16_384 + TaskTextLimits.inputBytes)
        for (id, draft) in drafts where !draftIDs.contains(id) {
            bytes += TaskTextLimits.inputBytes + 8_192 + (draft.inputProvenance?.retainedBytes ?? 0)
            include(draft.sourceTarget)
        }
        for review in pendingCommandReviews where !taskIDs.contains(review.id) { bytes += review.textBytes }
        for review in activeCommandReviews.values where !taskIDs.contains(review.id) { bytes += review.textBytes }
        bytes += snapshots.values.reduce(0) { $0 + ($1.selectedText?.utf8.count ?? 0) + $1.applicationName.utf8.count }
        return bytes
    }

    func registerDraft(_ draft: AIDraftDocument) -> Bool {
        guard !isShuttingDown, !isClearingHistory, !draft.isDiscarded,
              makeSessionRoom(draftSlots: 1, additionalBytes: TaskTextLimits.inputBytes + 8_192 + (draft.inputProvenance?.retainedBytes ?? 0) + (draft.sourceTarget?.selectedText?.utf8.count ?? 0) + (draft.sourceTarget?.applicationName.utf8.count ?? 0)) else {
            draft.discard(); admissionNotice(draft); return false
        }
        draftOrder.append(draft.id); drafts[draft.id] = draft
        return true
    }

    func removeSessionObjects(tasks taskIDs: Set<UUID>, drafts draftIDs: Set<UUID>) {
        guard !taskIDs.isEmpty || !draftIDs.isEmpty else { return }
        mutatingSession = true
        defer { mutatingSession = false }
        for id in draftIDs { drafts[id]?.discard(); drafts[id] = nil }
        draftOrder.removeAll { draftIDs.contains($0) }
        tasks.removeAll { taskIDs.contains($0.id) }
        for id in taskIDs { workflowUsageDependencies[id] = nil; workflowAIUsage[id] = nil; usageSummaryRevisions[id] = nil }
        for id in taskIDs { resultTargets[id] = nil; aiTaskIDs.remove(id); cancelledTaskIDs.remove(id); usageSummaryGenerations[id] = nil; invalidatedUsageRuns.remove(id); workflowCheckpoints[id] = nil; agentRunDefinitions[id] = nil; taskActivity[id] = nil; timedOutTaskIDs.remove(id); pausedAgentIDs.remove(id) }
        for draft in drafts.values where draft.latestRunID.map(taskIDs.contains) == true { draft.latestRunID = nil }
        proposalRequests = proposalRequests.filter { !draftIDs.contains($0.key) && !taskIDs.contains($0.value) }
        pendingCommandReviews.removeAll { taskIDs.contains($0.id) }
        activeCommandReviews = activeCommandReviews.filter { !taskIDs.contains($0.key) }
        if latestAutoCopyRunID.map(taskIDs.contains) == true { latestAutoCopyRunID = nil }
        onHistoryRemoved?(taskIDs, draftIDs)
    }

    func enqueueCommandReview(_ command: SavedCommand, runID: UUID) throws {
        let bytes = try JSONEncoder().encode(command).count
        guard pendingCommandReviews.count + activeCommandReviews.count < 10, makeSessionRoom(additionalBytes: bytes) else { throw SessionAdmissionError.capacity }
        pendingCommandReviews.append(.init(id: runID, command: command, textBytes: bytes))
        onReviewCommand?(command)
    }
    public func takeNextCommandReview() -> PendingCommandReview? {
        guard !pendingCommandReviews.isEmpty else { return nil }
        let review = pendingCommandReviews[0]
        activeCommandReviews[review.id] = review
        pendingCommandReviews.removeFirst()
        return review
    }
    public func finishCommandReview(_ id: UUID) { activeCommandReviews[id] = nil }
}
