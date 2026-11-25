import Foundation
import ExecutionCore

extension WorkbenchModel {
    func protectedChildIDs(_ receipts: [InvocationReceipt], parents: Set<UUID>) -> Set<UUID> {
        Set(receipts.filter { value in
            guard let parent = value.commandID?.split(separator:".").last, let id = UUID(uuidString:String(parent)) else { return false }
            return parents.contains(id)
        }.map(\.id))
    }
    func restoreHistorySnapshot(cli: [InvocationReceipt], ai: [InvocationReceipt], generation: UInt64) {
        guard !isShuttingDown, !isClearingHistory, historyGeneration == generation else { return }
        let aiIDs = Set(ai.map(\.id))
        let workspaceParents = Set(cli.filter { $0.desktopWorkspaceRun != nil }.map(\.id))
        let topLevelCLI = cli.filter { $0.desktopWorkspace.map { !workspaceParents.contains($0.parentID) } ?? true }
        let merged = (topLevelCLI + ai).sorted {
            // 崩溃后的未知结果优先可见，避免长任务被大量后来完成的短任务挤出首屏历史。
            if ($0.state == .interrupted) != ($1.state == .interrupted) { return $0.state == .interrupted }
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for receipt in merged.prefix(sessionLimits.tasks) {
            // 恢复读取与清理会await；旧快照不能覆盖本进程随后确认的结果。
            guard !tasks.contains(where: { $0.id == receipt.id }) else { continue }
            if aiIDs.contains(receipt.id) { restoreAIReceipt(receipt) } else {
                restoreReceipt(receipt)
                if let report = DesktopWorkspaceRunResult.recover(parent: receipt, children: cli), let index = tasks.firstIndex(where: { $0.id == receipt.id }) {
                    tasks[index].titleKey = "Desktop workspace"
                    tasks[index].desktopWorkspaceID = receipt.desktopWorkspaceRun?.workspaceID
                    tasks[index].desktopWorkspaceResult = report
                    tasks[index].noticeMessage = desktopWorkspaceNotice(report)
                }
            }
        }
    }

    func startReceiptMaintenance() {
        receiptMaintenanceTask?.cancel()
        receiptMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.maintainTaskHistory()
            }
        }
    }
    func maintainTaskHistory() async {
        guard !isShuttingDown, !isClearingHistory else { return }
        let protected = executionReservations.union(taskHandles.keys)
        let cli = await invocationStore.maintain(protecting: protected)
        let ai = await aiInvocationStore.maintain(protecting: protected)
        let currentParents = executionReservations.union(taskHandles.keys)
        let tools = await agentToolStore.maintain(protectingParents:currentParents)
        guard !isShuttingDown, !isClearingHistory else { return }
        if cli.failure != nil || ai.failure != nil || tools.failure != nil || !tools.limitsSatisfied || !cli.limitsSatisfied || !ai.limitsSatisfied {
            workspaceNoticeMessage = noticeKey("Some task records could not be maintained. Running and unconfirmed tasks were kept.")
        }
    }

    public func clearFinishedHistory() async {
        guard !isShuttingDown, !isClearingHistory else { return }
        isClearingHistory = true; historyGeneration &+= 1
        clearTextContextInputs()
        let generation = historyGeneration
        let protected = executionReservations.union(taskHandles.keys)
        let candidates = tasks.filter { $0.finishedAt != nil && !protected.contains($0.id) }
        let memoryCLI = Set(candidates.filter { $0.aiUsageSummary == nil && !$0.receiptIsAI }.map(\.id))
        let memoryAI = Set(candidates.filter { $0.aiUsageSummary != nil || $0.receiptIsAI }.map(\.id))
        let activeDrafts = Set(tasks.filter { protected.contains($0.id) }.compactMap(\.draftID))
        let idleDrafts = Dictionary(uniqueKeysWithValues: drafts.values.filter { !activeDrafts.contains($0.id) }.map { ($0.id, $0.revision) })
        defer { isClearingHistory = false }
        let cliSnapshot = await invocationStore.list(), aiSnapshot = await aiInvocationStore.list()
        // 显式确认清除可覆盖尚未发布到UI的旧恢复记录；当前进程lease不受ack影响。
        await invocationStore.acknowledgeRecovery(); await aiInvocationStore.acknowledgeRecovery()
        let cliIDs = Set(cliSnapshot.filter { $0.state.isTerminal }.map(\.id)).union(memoryCLI).subtracting(protected)
        let aiIDs = Set(aiSnapshot.filter { $0.state.isTerminal }.map(\.id)).union(memoryAI).subtracting(protected)
        let cli = await invocationStore.clearFinished(onlyIDs: cliIDs, excluding: protected)
        let ai = await aiInvocationStore.clearFinished(onlyIDs: aiIDs, excluding: protected)
        await agentToolStore.acknowledgeRecovery()
        let tools = await agentToolStore.clearFinished(protectingParents:executionReservations.union(taskHandles.keys))
        guard !isShuttingDown, historyGeneration == generation else { return }
        var removed: Set<UUID> = []
        if cli.failure == nil { removed.formUnion(cliIDs.subtracting(cli.remainingIDs)) }
        if ai.failure == nil { removed.formUnion(aiIDs.subtracting(ai.remainingIDs)) }
        let editedDrafts = applyConfirmedHistoryClear(taskIDs: removed, draftRevisions: idleDrafts)
        isClearingHistory = false
        // 失败组若尚未显示过，仍展示其保留记录；不把清除失败伪装为空历史。
        restoreHistorySnapshot(cli: cliSnapshot.filter { cli.remainingIDs.contains($0.id) },
            ai: aiSnapshot.filter { ai.remainingIDs.contains($0.id) }, generation: generation)
        let remainingCandidates = cliIDs.intersection(cli.remainingIDs).union(aiIDs.intersection(ai.remainingIDs))
        if cli.failure != nil || ai.failure != nil || tools.failure != nil || !remainingCandidates.isEmpty {
            settingsNoticeMessage = noticeKey("History was only partly cleared. Some tasks are still finishing or records could not be removed. Try again later.")
        } else if editedDrafts > 0 {
            settingsNoticeMessage = noticeKey("Finished history cleared. Drafts edited while clearing were kept.")
        } else { settingsNoticeMessage = noticeKey("Finished tasks and idle AI drafts cleared. Running tasks were kept.") }
    }

    @discardableResult func applyConfirmedHistoryClear(taskIDs: Set<UUID>, draftRevisions: [UUID: UUID]) -> Int {
        let unchanged = Set(draftRevisions.keys.filter { drafts[$0]?.revision == draftRevisions[$0] })
        let edited = draftRevisions.keys.filter { drafts[$0] != nil && !unchanged.contains($0) }.count
        removeSessionObjects(tasks: taskIDs, drafts: unchanged)
        return edited
    }

    func handleUsageMaintenance(_ report: AIUsageMaintenanceReport) {
        guard !isShuttingDown, report.trigger != .clear else { return }
        for index in tasks.indices where report.removedIDs.contains(tasks[index].id) {
            let id = tasks[index].id
            invalidatedUsageRuns.insert(id); tasks[index].aiUsageSummary = .unknown
        }
        if !report.isComplete { workspaceNoticeMessage = noticeKey("Some AI usage records could not be maintained. Review or clear usage history in Privacy settings.") }
    }

    public func clearAIUsageHistory() async {
        guard !isShuttingDown, !isClearingUsage else { return }
        isClearingUsage = true; usageHistoryGeneration &+= 1
        let generation = usageHistoryGeneration
        let candidates = Set(tasks.filter { $0.aiUsageSummary != nil }.map(\.id))
        defer { isClearingUsage = false }
        let report = await usageMetadataStore.clear()
        guard !isShuttingDown, usageHistoryGeneration == generation else { return }
        if report.didReadDirectory {
            for index in tasks.indices where candidates.contains(tasks[index].id) && !report.remainingIDs.contains(tasks[index].id) {
                let id = tasks[index].id
                guard report.removedIDs.contains(id) || !executionReservations.contains(id) else { continue }
                guard usageSummaryGenerations[id, default: 0] < generation else { continue }
                tasks[index].aiUsageSummary = .unknown; usageSummaryGenerations[id] = generation
                invalidatedUsageRuns.insert(id)
            }
        }
        settingsNoticeMessage = report.isComplete
            ? noticeKey("AI usage history cleared. Running requests may create new records when they finish.")
            : noticeKey("AI usage history was only partly cleared. Some records remain; check permissions and try again.")
    }
}
