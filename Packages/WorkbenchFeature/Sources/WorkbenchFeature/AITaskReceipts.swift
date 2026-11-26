import Foundation
import ExecutionCore

/// P1 只保存最小调用元数据；正文、用户动作名、模型消息、AX 目标和密钥不进入回执。
enum AITaskReceiptKind: String {
    case text = "AI action"
    case proposal = "Command proposal"
    case readOnlyAgent = "Read-only agent"
    case agent = "Agent run"
    case workflow = "Workflow run"
    case context = "Text import"
}

enum AITaskReceiptError: Error { case intentUnavailable }

extension WorkbenchModel {
    @discardableResult func beginAIReceipt(id: UUID, kind: AITaskReceiptKind, authorization: ExecutionRequest,
                        runDefinition: RunDefinitionReference? = nil, attempt: AttemptExecutionContext? = nil,
                        materialCapture: TaskMaterialCapture? = nil, configurationFingerprint: String? = nil, runTokenBudget: RunTokenBudgetSnapshot? = nil) async throws -> InvocationWorkerOwnership {
        try await beginOwnedReceipt(store: aiInvocationStore, id: id, name: kind.rawValue, authorization: authorization,
                                    configurationFingerprint: configurationFingerprint,
                                    runDefinition: runDefinition, attempt: attempt, materialCapture: materialCapture, runTokenBudget: runTokenBudget)
    }

    func finishAIReceipt(_ id: UUID, owner: InvocationWorkerOwnership? = nil) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let state: ExecutionState
        switch task.status {
        case .completed, .draftReady: state = .succeeded
        case .cancelled: state = .cancelled
        case .timedOut: state = .timedOut
        case .interrupted, .paused: state = .interrupted
        default: state = .failed
        }
        var message = task.status == .draftReady ? "ai.proposal.draftReady" : "ai." + task.status.rawValue
        if task.status == .paused, task.runTokenPauseReason == .thresholdReached { message = "ai.paused.tokens" }
        if task.status == .paused, task.runTokenPauseReason == .usageUnavailable { message = "ai.paused.usage" }
        do {
            if let owner {
                guard owner.id == id else { throw InvocationStoreError.staleRecovery }
                try await owner.finish(.init(state: state, message: message), runTokenBudget: task.runTokenBudget)
            } else { try await aiInvocationStore.finish(id: id, result: .init(state: state, message: message), runTokenBudget: task.runTokenBudget) }
        }
        catch {
            // 实际模型结果不因落盘失败被改写；旧 intent 仍是重启时的保守 unknown 围栏。
            let notice = noticeKey("AI finished, but its task receipt could not be saved. Do not retry automatically.")
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].noticeMessage = tasks[index].noticeMessage.appending(notice)
            }
            workspaceNoticeMessage = notice
        }
    }

    func restoreAIReceipt(_ receipt: InvocationReceipt) {
        guard !isDesktopReview else { return }
        // 启动读取与用户新建任务可能交错；当前进程已有任务不能被恢复列表重复插入。
        guard !tasks.contains(where: { $0.id == receipt.id }) else { return }
        guard !isShuttingDown, !isClearingHistory, makeSessionRoom(taskSlots: 1) else { return }
        let kind = AITaskReceiptKind(rawValue: receipt.name) ?? .text
        let paused = ["ai.paused", "ai.paused.tokens", "ai.paused.usage"].contains(receipt.message)
        let status: TaskStatus = receipt.message == "ai.proposal.draftReady" ? .draftReady : (paused ? .paused : stateLabel(receipt.state))
        var task = RunningTaskItem(id: receipt.id, title: L(kind.rawValue), state: status,
            output: "",
            startedAt: receipt.startedAt, finishedAt: receipt.finishedAt, titleKey: kind.rawValue)
        task.restoredFromReceipt = true
        task.receiptIsAI = true
        task.runAttempt = receipt.runAttempt
        if let budget = receipt.runTokenBudget {
            task.runTokenBudget = budget.status == .awaitingUsage ? .init(maximumTokens: budget.maximumTokens, knownTokens: budget.knownTokens, completedTurns: budget.completedTurns, status: .usageUnavailable) : budget
        }
        if receipt.message == "ai.paused.tokens" { task.runTokenPauseReason = .thresholdReached; task.noticeMessage = agentTokenPauseNotice(.thresholdReached) }
        if receipt.message == "ai.paused.usage" { task.runTokenPauseReason = .usageUnavailable; task.noticeMessage = agentTokenPauseNotice(.usageUnavailable) }
        if kind != .context { task.aiUsageSummary = .unknown }
        task.outputIsIncomplete = status == .interrupted
        if status == .interrupted { task.noticeMessage = noticeKey("Previous execution was interrupted. Outcome is unknown; it was not replayed.") }
        // 没有 draft、Task、resultTarget 或 callback；恢复只展示，不重发、不复制、不审阅。
        tasks.append(task)
        if kind == .workflow { loadRestoredWorkflowUsage(receipt.id) }
        else if kind != .context { loadRestoredAIUsage(receipt.id, interrupted: status == .interrupted) }
    }
}
