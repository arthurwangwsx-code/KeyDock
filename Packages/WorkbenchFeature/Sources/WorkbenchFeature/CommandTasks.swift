import AppKit
import Foundation
import ExecutionCore
import MacAdapters

extension WorkbenchModel {
    func restoreReceipt(_ receipt: InvocationReceipt) {
        tasks.append(RunningTaskItem(id: receipt.id, title: receipt.name, state: receipt.message == "terminal.handedOff" ? L("Opened in Terminal") : stateLabel(receipt.state), output: receipt.state == .interrupted ? L("Previous execution was interrupted. Outcome is unknown; it was not replayed.") : "", exitCode: receipt.exitCode, startedAt: receipt.startedAt, finishedAt: receipt.finishedAt))
    }
    public func runCommand(_ command: SavedCommand, caller: ExecutionCaller = .user) {
        let id = UUID()
        let authorization: ExecutionRequest
        let configFingerprint: String
        do {
            configFingerprint = try fingerprint(command)
            authorization = try authorizeHostAction(id: "command." + command.id.uuidString, effect: .executeProcess, resource: configFingerprint, caller: caller, invocation: id)
        } catch { showError(error); return }
        guard !command.executable.isEmpty, !command.name.isEmpty else { message = L("Name and executable are required"); return }
        tasks.insert(RunningTaskItem(id: id, title: command.name, state: L("Queued")), at: 0)
        selectedTaskID = id; section = .tasks
        taskHandles[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await invocationStore.begin(id: id, name: command.name, commandID: authorization.commandID, commandVersion: authorization.commandVersion, configurationFingerprint: configFingerprint, caller: authorization.caller.rawValue)
                try Task.checkCancellation()
                if cancelledTaskIDs.contains(id) { throw CancellationError() }
                if command.interactive {
                    try openInTerminal(command)
                    let result = ProcessResult(state: .succeeded, exitCode: nil, message: "terminal.handedOff")
                    await persistResult(id, result: result)
                    updateTask(id, state: L("Opened in Terminal"), output: L("Interactive execution is managed by Terminal; output and cancellation remain there."), finished: true)
                } else {
                    let events = await processRunner.run(command, id: id)
                    if cancelledTaskIDs.contains(id) || Task.isCancelled { await processRunner.cancel(id) }
                    for await event in events {
                        switch event {
                        case .started: updateTask(id, state: L("Running"))
                        case let .output(text, isError):
                            _ = isError; appendOutput(id, text: text.replacingOccurrences(of: "[process.outputTruncated]", with: L("Output limit reached; remaining output was discarded")))
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
            message = L("Execution finished, but its receipt could not be saved. Do not rerun automatically.")
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
    func appendOutput(_ id: UUID, text: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let limit = 1_048_576
        if tasks[i].output.utf8.count < limit { tasks[i].output += text }
    }
    func updateTask(_ id: UUID, state: String, output: String? = nil, finished: Bool = false, exitCode: Int32? = nil) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].state = state
        if let output { tasks[i].output = output }
        if finished { tasks[i].finishedAt = Date(); tasks[i].exitCode = exitCode }
    }
    func stateLabel(_ state: ExecutionState) -> String {
        switch state { case .queued: L("Queued"); case .running: L("Running"); case .succeeded: L("Completed"); case .failed: L("Failed"); case .cancelled: L("Cancelled"); case .timedOut: L("Timed out"); case .interrupted: L("Interrupted / unknown outcome") }
    }
    private func openInTerminal(_ command: SavedCommand) throws {
        let folder = directory.appendingPathComponent("terminal-launches", isDirectory: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let executable = ([command.executable] + command.arguments).map(quote).joined(separator: " ")
        let environment = command.environment.sorted(by: { $0.key < $1.key }).map { quote($0.key + "=" + $0.value) }.joined(separator: " ")
        let script = "#!/bin/zsh\n/bin/rm -f -- \"$0\"\ncd -- \(quote(command.workingDirectory)) || exit 1\nexec /usr/bin/env \(environment) \(executable)\n"
        try PrivateFiles.write(Data(script.utf8), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        guard NSWorkspace.shared.open(file) else { try? FileManager.default.removeItem(at: file); throw CocoaError(.executableLoad) }
    }
}
