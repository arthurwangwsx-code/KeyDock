import Foundation
import AICore
import ExecutionCore

public enum SavedCommandAITool {
    public static func make(command: SavedCommand, resourceFingerprint: String, runner: ProcessRunner) throws -> ScopedAITool {
        try command.validate()
        guard !command.interactive else { throw AgentToolError.invalidDefinition }
        let name = "command_" + command.id.uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let definition = AIToolDefinition(name:name,description:"Run the saved command named " + String(command.name.prefix(128)) + ". The user must approve each call. Arguments and environment cannot be changed by the model.",parameters:["type":.string("object"),"properties":.object([:]),"required":.array([]),"additionalProperties":.bool(false)])
        let summary = command.executable + " " + command.arguments.map { String(reflecting:$0) }.joined(separator:" ") + "\n" + command.workingDirectory
        return ScopedAITool(definition:definition,effects:[.executeProcess],resource:.exact(namespace:"keydock.saved-command",identifier:resourceFingerprint),approvalSummary:summary) { _,id in
            try await withTaskCancellationHandler {
                var output = "", final: ProcessResult?, exceeded = false
                for await event in await runner.run(command,id:id) {
                    switch event {
                    case .started: break
                    case .output(let delta,_):
                        if !exceeded && output.utf8.count + delta.utf8.count <= 65_536 { output += delta }
                        else { exceeded = true; await runner.cancel(id) }
                    case .finished(let result): final = result
                    }
                    if Task.isCancelled { await runner.cancel(id) }
                }
                if Task.isCancelled { await runner.cancel(id) }
                await runner.waitForCompletion(id)
                try Task.checkCancellation()
                if exceeded { throw AIProviderError.outputLimit }
                guard final?.state == .succeeded else { throw AgentToolError.toolFailed }
                return output.isEmpty ? "Command completed with exit code 0." : output
            } onCancel: { Task { await runner.cancel(id) } }
        }
    }
}
