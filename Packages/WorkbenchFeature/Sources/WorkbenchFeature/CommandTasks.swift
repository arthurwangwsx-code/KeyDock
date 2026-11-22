import AppKit
import Foundation
import ExecutionCore
import MacAdapters

extension WorkbenchModel {
    func restoreReceipt(_ receipt: InvocationReceipt) {
        guard !tasks.contains(where: { $0.id == receipt.id }) else { return }
        guard !isShuttingDown, !isClearingHistory, makeSessionRoom(taskSlots: 1) else { return }
        tasks.append(RunningTaskItem(id: receipt.id, title: receipt.name, state: receipt.message == "terminal.handedOff" ? .handedOff : stateLabel(receipt.state), output: "", exitCode: receipt.exitCode, startedAt: receipt.startedAt, finishedAt: receipt.finishedAt))
        tasks[tasks.count - 1].restoredFromReceipt = true
        if receipt.message == "terminal.handoffUnknown" {
            tasks[tasks.count - 1].noticeMessage = noticeKey("Terminal did not confirm opening the command. It may already be running. Check Terminal before retrying.")
        } else if receipt.state == .interrupted { tasks[tasks.count - 1].noticeMessage = noticeKey("Previous execution was interrupted. Outcome is unknown; it was not replayed.") }
    }
    @discardableResult public func runCommand(_ command: SavedCommand, caller: ExecutionCaller = .user, showWorkspace: Bool = true) -> UUID? {
        guard !isShuttingDown else { return nil }
        let id = UUID()
        let authorization: ExecutionRequest
        let configFingerprint: String
        do {
            try command.validate()
            configFingerprint = try fingerprint(command)
            authorization = try authorizeHostAction(id: "command." + command.id.uuidString, operation: .runCommand, resource: configFingerprint, availableContext: [.workingDirectory], caller: caller, invocation: id)
        } catch is SavedCommandValidationError {
            let notice = noticeKey("Check name, absolute paths, arguments, environment and timeout")
            if showWorkspace { settingsNoticeMessage = notice } else { launcherNoticeMessage = notice }; return nil
        } catch { showError(error); return nil }
        guard reserveExecution(id) else { return nil }
        tasks.insert(RunningTaskItem(id: id, title: command.name, state: .queued), at: 0)
        taskHandles[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await invocationStore.begin(id: id, name: command.name, commandID: authorization.commandID, commandVersion: authorization.commandVersion, configurationFingerprint: configFingerprint, caller: authorization.caller.rawValue, initialMessage: command.interactive ? "terminal.handoffIntent" : "")
                try Task.checkCancellation()
                guard !isShuttingDown else { throw CancellationError() }
                if cancelledTaskIDs.contains(id) { throw CancellationError() }
                if command.interactive {
                    let outcome = try await openInTerminal(command, id: id)
                    await completeTerminalHandoff(id, outcome: outcome)
                } else {
                    let events = await processRunner.run(command, id: id)
                    if cancelledTaskIDs.contains(id) || Task.isCancelled { await processRunner.cancel(id) }
                    for await event in events {
                        switch event {
                        case .started: updateTask(id, state: .running)
                        case let .output(text, isError):
                            _ = isError
                            let upstreamTruncated = text.contains("[process.outputTruncated]")
                            let accepted = appendOutput(id, text: text.replacingOccurrences(of: "[process.outputTruncated]", with: ""))
                            if upstreamTruncated || !accepted { markIncompleteOutput(id, notice: noticeKey("Output limit reached; remaining output was discarded")) }
                        case let .finished(result):
                            await persistResult(id, result: result)
                            updateTask(id, state: stateLabel(result.state), finished: true, exitCode: result.exitCode)
                            if result.state == .failed, let index = tasks.firstIndex(where: { $0.id == id }) {
                                tasks[index].noticeMessage = tasks[index].noticeMessage.appending(noticeKey("Command failed. Check executable, arguments and directory."))
                            }
                        }
                    }
                }
            } catch {
                let cancelled = error is CancellationError || cancelledTaskIDs.contains(id)
                let result = ProcessResult(state: cancelled ? .cancelled : .failed, exitCode: nil, message: cancelled ? "host.cancelled" : "host.executionFailed")
                try? await invocationStore.finish(id: id, result: result)
                updateTask(id, state: stateLabel(result.state), finished: true)
                if let index = tasks.firstIndex(where: { $0.id == id }) {
                    tasks[index].noticeMessage = cancelled ? noticeKey("Cancelled before execution") : noticeKey("Command could not be started or its receipt could not be saved.")
                }
            }
            finishExecutionReservation(id)
        }
        if showWorkspace { onOpenWorkspace?(.tasks(id)) }
        return id
    }
    private func persistResult(_ id: UUID, result: ProcessResult) async {
        do { try await invocationStore.finish(id: id, result: result) }
        catch {
            workspaceNoticeMessage = noticeKey("Execution finished, but its receipt could not be saved. Do not rerun automatically.")
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].noticeMessage = tasks[index].noticeMessage.appending(noticeKey("Receipt unavailable; outcome after restart may be unknown."))
            }
        }
    }
    public func cancelTask(_ id: UUID) {
        guard tasks.first(where: { $0.id == id })?.canCancel == true else { return }
        // CLI 消费任务继续等待 finished 回执；AI 则通过取消网络任务终止。
        cancelledTaskIDs.insert(id)
        if aiTaskIDs.contains(id) { taskHandles[id]?.cancel() }
        else { Task { await processRunner.cancel(id) } }
    }
    func updateTask(_ id: UUID, state: TaskStatus, output: String? = nil, finished: Bool = false, exitCode: Int32? = nil) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = state
        if let output { tasks[i].output = output }
        if finished { tasks[i].finishedAt = Date(); tasks[i].exitCode = exitCode }
    }
    func stateLabel(_ state: ExecutionState) -> TaskStatus {
        switch state { case .queued: .queued; case .running: .running; case .succeeded: .completed; case .failed: .failed; case .cancelled: .cancelled; case .timedOut: .timedOut; case .interrupted: .interrupted }
    }
    private func openInTerminal(_ command: SavedCommand, id: UUID) async throws -> TerminalHandoffOutcome {
        let folder = directory.appendingPathComponent("terminal-launches", isDirectory: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        let script = try TerminalLaunchScript.make(command: command, launchFile: file)
        do {
            try PrivateFiles.write(Data(script.utf8), to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        let outcome = await terminalHandoff.open(file: file, beforeSubmission: {
            !self.isShuttingDown && !self.cancelledTaskIDs.contains(id) && !Task.isCancelled
        }, onSubmission: {
            self.updateTask(id, state: .handoffPending)
            self.setTerminalNotice(id, noticeKey("Terminal handoff requested. Manage execution in Terminal; this request cannot be recalled."))
        })
        // unknown 的脚本仍可能被 OS 打开，不能把停止等待伪装成撤回请求。
        if outcome == .notSubmitted || outcome == .rejected { try? FileManager.default.removeItem(at: file) }
        return outcome
    }
    private func completeTerminalHandoff(_ id: UUID, outcome: TerminalHandoffOutcome) async {
        let result: ProcessResult
        let state: TaskStatus
        switch outcome {
        case .notSubmitted:
            result = .init(state: .cancelled, message: "host.cancelled")
            state = .cancelled
            setTerminalNotice(id, noticeKey("Cancelled before execution"))
        case .acknowledged:
            result = .init(state: .succeeded, message: "terminal.handedOff")
            state = .handedOff
            setTerminalNotice(id, noticeKey("Interactive execution is managed by Terminal; output and cancellation remain there."))
        case .rejected:
            result = .init(state: .failed, message: "terminal.handoffFailed")
            state = .failed
            setTerminalNotice(id, noticeKey("Terminal could not open this command. Check Terminal before retrying."))
        case .unknown:
            result = .init(state: .interrupted, message: "terminal.handoffUnknown")
            state = .interrupted
            setTerminalNotice(id, noticeKey("Terminal did not confirm opening the command. It may already be running. Check Terminal before retrying."))
        }
        await persistResult(id, result: result)
        updateTask(id, state: state, finished: true)
    }
    private func setTerminalNotice(_ id: UUID, _ text: LocalizedNotice) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].noticeMessage = text
    }
}
