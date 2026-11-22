import Foundation
import ExecutionCore

/// P1 只保存最小调用元数据；正文、用户动作名、模型消息、AX 目标和密钥不进入回执。
enum AITaskReceiptKind: String {
    case text = "AI action"
    case proposal = "Command proposal"
    case readOnlyAgent = "Read-only agent"
}

enum AITaskReceiptError: Error { case intentUnavailable }

extension WorkbenchModel {
    func beginAIReceipt(id: UUID, kind: AITaskReceiptKind, authorization: ExecutionRequest) async throws {
        do {
            try await aiInvocationStore.begin(id: id, name: kind.rawValue,
                commandID: authorization.commandID, commandVersion: authorization.commandVersion,
                caller: authorization.caller.rawValue)
        } catch { throw AITaskReceiptError.intentUnavailable }
    }

    func finishAIReceipt(_ id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let state: ExecutionState
        switch task.status {
        case .completed, .draftReady: state = .succeeded
        case .cancelled: state = .cancelled
        case .timedOut: state = .timedOut
        case .interrupted: state = .interrupted
        default: state = .failed
        }
        let message = task.status == .draftReady ? "ai.proposal.draftReady" : "ai." + task.status.rawValue
        do { try await aiInvocationStore.finish(id: id, result: .init(state: state, message: message)) }
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
        // 启动读取与用户新建任务可能交错；当前进程已有任务不能被恢复列表重复插入。
        guard !tasks.contains(where: { $0.id == receipt.id }) else { return }
        guard !isShuttingDown, !isClearingHistory, makeSessionRoom(taskSlots: 1) else { return }
        let kind = AITaskReceiptKind(rawValue: receipt.name) ?? .text
        let status: TaskStatus = receipt.message == "ai.proposal.draftReady" ? .draftReady : stateLabel(receipt.state)
        var task = RunningTaskItem(id: receipt.id, title: L(kind.rawValue), state: status,
            output: "",
            startedAt: receipt.startedAt, finishedAt: receipt.finishedAt, titleKey: kind.rawValue)
        task.restoredFromReceipt = true
        task.aiUsageSummary = .unknown
        task.outputIsIncomplete = status == .interrupted
        if status == .interrupted { task.noticeMessage = noticeKey("Previous execution was interrupted. Outcome is unknown; it was not replayed.") }
        // 没有 draft、Task、resultTarget 或 callback；恢复只展示，不重发、不复制、不审阅。
        tasks.append(task)
        loadRestoredAIUsage(receipt.id, interrupted: status == .interrupted)
    }
}
