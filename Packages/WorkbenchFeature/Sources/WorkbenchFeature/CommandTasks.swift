import AppKit
import Foundation
import ExecutionCore
import MacAdapters

extension WorkbenchModel {
    func restoreReceipt(_ receipt: InvocationReceipt) {
        tasks.append(RunningTaskItem(id: receipt.id, title: receipt.name, state: receipt.message == "terminal.handedOff" ? .handedOff : stateLabel(receipt.state), output: "", exitCode: receipt.exitCode, startedAt: receipt.startedAt, finishedAt: receipt.finishedAt))
        tasks[tasks.count - 1].restoredFromReceipt = true
        if receipt.state == .interrupted { tasks[tasks.count - 1].notice = L("Previous execution was interrupted. Outcome is unknown; it was not replayed.") }
    }
    public func runCommand(_ command: SavedCommand, caller: ExecutionCaller = .user, showWorkspace: Bool = true) {
        guard !isShuttingDown else { return }
        let id = UUID()
        let authorization: ExecutionRequest
        let configFingerprint: String
        do {
            try command.validate()
            configFingerprint = try fingerprint(command)
            authorization = try authorizeHostAction(id: "command." + command.id.uuidString, operation: .runCommand, resource: configFingerprint, availableContext: [.workingDirectory], caller: caller, invocation: id)
        } catch is SavedCommandValidationError {
            let notice = L("Check name, absolute paths, arguments, environment and timeout")
            if showWorkspace { settingsNotice = notice } else { launcherNotice = notice }; return
        } catch { showError(error); return }
        tasks.insert(RunningTaskItem(id: id, title: command.name, state: .queued), at: 0)
        if showWorkspace { onOpenWorkspace?(.tasks(id)) }
        taskHandles[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await invocationStore.begin(id: id, name: command.name, commandID: authorization.commandID, commandVersion: authorization.commandVersion, configurationFingerprint: configFingerprint, caller: authorization.caller.rawValue)
                try Task.checkCancellation()
                if cancelledTaskIDs.contains(id) { throw CancellationError() }
                if command.interactive {
                    try await openInTerminal(command)
                    let result = ProcessResult(state: .succeeded, exitCode: nil, message: "terminal.handedOff")
                    await persistResult(id, result: result)
                    updateTask(id, state: .handedOff, output: L("Interactive execution is managed by Terminal; output and cancellation remain there."), finished: true)
                } else {
                    let events = await processRunner.run(command, id: id)
                    if cancelledTaskIDs.contains(id) || Task.isCancelled { await processRunner.cancel(id) }
                    for await event in events {
                        switch event {
                        case .started: updateTask(id, state: .running)
                        case let .output(text, isError):
                            _ = isError
                            let upstreamTruncated = text.contains("[process.outputTruncated]")
                            let accepted = appendOutput(id, text: text.replacingOccurrences(of: "[process.outputTruncated]", with: L("Output limit reached; remaining output was discarded")))
                            if upstreamTruncated || !accepted { markIncompleteOutput(id, notice: L("Output limit reached; remaining output was discarded")) }
                        case let .finished(result):
                            await persistResult(id, result: result)
                            updateTask(id, state: stateLabel(result.state), finished: true, exitCode: result.exitCode)
                            if result.state == .failed { appendOutput(id, text: "\n" + L("Command failed. Check executable, arguments and directory.")) }
                        }
                    }
                }
            } catch {
                let cancelled = error is CancellationError || cancelledTaskIDs.contains(id)
                let result = ProcessResult(state: cancelled ? .cancelled : .failed, exitCode: nil, message: cancelled ? "host.cancelled" : "host.executionFailed")
                try? await invocationStore.finish(id: id, result: result)
                updateTask(id, state: stateLabel(result.state), output: cancelled ? L("Cancelled before execution") : L("Command could not be started or its receipt could not be saved."), finished: true)
            }
            taskHandles[id] = nil; cancelledTaskIDs.remove(id)
        }
    }
    private func persistResult(_ id: UUID, result: ProcessResult) async {
        do { try await invocationStore.finish(id: id, result: result) }
        catch {
            workspaceNotice = L("Execution finished, but its receipt could not be saved. Do not rerun automatically.")
            appendOutput(id, text: "\n" + L("Receipt unavailable; outcome after restart may be unknown."))
        }
    }
    public func cancelTask(_ id: UUID) {
        guard tasks.first(where: { $0.id == id })?.isRunning == true else { return }
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
    private func openInTerminal(_ command: SavedCommand) async throws {
        let folder = directory.appendingPathComponent("terminal-launches", isDirectory: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        let script = try TerminalLaunchScript.make(command: command, launchFile: file)
        try PrivateFiles.write(Data(script.utf8), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        do {
            let workspace = NSWorkspace.shared
            // 显式选择 Terminal，不依赖用户对 .command 文件的默认编辑器关联。
            guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw CocoaError(.executableLoad) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await workspace.open([file], withApplicationAt: terminal, configuration: configuration)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
