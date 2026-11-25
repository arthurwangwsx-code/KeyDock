import Foundation
import CryptoKit
import AutomationCore
import AICore
import ExecutionCore
import AgentCore

struct PreparedWorkflowAI: Sendable { let action: AIActionPreset; let provider: ChatCompletionsProvider }
struct PreparedWorkflowCommand: Sendable { let command:SavedCommand; let contract:FrozenCommandContribution }
struct WorkflowAIUsage: Sendable { let id: UUID; let endpoint: URL; let model: String; let usage: AIUsageAccumulator; let outcome: String }

/// 只有已编译且用户已启动的冻结计划能构造宿主。它拥有真实子任务，Core超时不释放资源lease。
actor WorkflowExecutionHost {
    let commands: [UUID: PreparedWorkflowCommand]
    let actions: [UUID: PreparedWorkflowAI]
    let runner: ProcessRunner
    let journal: InvocationStore
    let manual: @Sendable (WorkflowHostRequest) async -> String?
    let onUsage: @Sendable (WorkflowAIUsage) async -> Void
    let approve: @Sendable (AgentToolApproval) async throws -> Bool
    var active: [UUID: Task<WorkflowHostResult,Never>] = [:]
    var closed = false
    init(commands:[UUID:PreparedWorkflowCommand],actions:[UUID:PreparedWorkflowAI],runner:ProcessRunner,journal:InvocationStore,
         manual:@escaping @Sendable (WorkflowHostRequest) async -> String?,onUsage:@escaping @Sendable (WorkflowAIUsage) async -> Void,
         approve:@escaping @Sendable (AgentToolApproval) async throws -> Bool) {
        self.commands = commands; self.actions = actions; self.runner = runner; self.journal = journal; self.manual = manual; self.onUsage = onUsage; self.approve = approve
    }
    func invoke(_ request: WorkflowHostRequest) async throws -> WorkflowHostResult {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
        let id = UUID(), commands = commands, actions = actions, runner = runner, journal = journal, manual = manual, onUsage = onUsage, approve = approve
        let task = Task { await Self.perform(request,id:id,commands:commands,actions:actions,runner:runner,journal:journal,manual:manual,onUsage:onUsage,approve:approve) }
        active[id] = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        active[id] = nil; return result
    }
    func close(cancel: Bool) async {
        closed = true
        let handles = active.values
        if cancel { for handle in handles { handle.cancel() } }
        for handle in handles { _ = await handle.value }
    }
    nonisolated private static func perform(_ request: WorkflowHostRequest,id:UUID,commands:[UUID:PreparedWorkflowCommand],actions:[UUID:PreparedWorkflowAI],runner:ProcessRunner,journal:InvocationStore,manual:@escaping @Sendable (WorkflowHostRequest) async -> String?,onUsage:@escaping @Sendable (WorkflowAIUsage) async -> Void,approve:@escaping @Sendable (AgentToolApproval) async throws -> Bool) async -> WorkflowHostResult {
        var began = false, dispatched = false, finishAttempted = false
        do {
            try Task.checkCancellation()
            if case .manualInput = request.operation {
                guard request.allowsInteraction, let value = await manual(request), value.utf8.count <= TaskTextLimits.inputBytes else { return .init(outcome:.cancelled) }
                try Task.checkCancellation(); return .init(outcome:.succeeded,output:value)
            }
            let effect: ExecutionEffect, resource: String
            var resolvedCommand: SavedCommand?
            var contract: FrozenCommandContribution?
            switch request.operation {
            case .savedCommand(let commandID):
                guard let prepared = commands[commandID], !prepared.command.interactive else { return .init(outcome:.failed) }
                let command = prepared.command; contract = prepared.contract
                let bound = try WorkflowCommandBinding.apply(request.input,to:command); resolvedCommand = bound
                if command.arguments.contains("{{input}}") {
                    guard request.allowsInteraction else { return .init(outcome:.failed) }
                    let summary = bound.executable+" "+bound.arguments.map{String(reflecting:$0)}.joined(separator:" ")+"\n"+bound.workingDirectory
                    guard try await approve(.init(id:id,runID:request.runID,toolName:"workflow_command",summary:summary,effects:[.executeProcess])) else { return .init(outcome:.cancelled) }
                    try Task.checkCancellation()
                }
                effect = .executeProcess; resource = try prepared.contract.fingerprint(bound)
            case .aiAction(let actionID):
                guard let ai = actions[actionID] else { return .init(outcome:.failed) }
                effect = .network; resource = ai.provider.configuration.endpoint.absoluteString+"|"+ai.provider.configuration.model+"|"+ai.action.prompt
            default: return .init(outcome:.failed)
            }
            let scope = ExecutionResourceScope.exact(namespace:"keydock.workflow-resource",identifier:SHA256.hash(data:Data(resource.utf8)).map{String(format:"%02x",$0)}.joined())
            let commandID = "keydock.workflow."+request.definitionID.uuidString
            let authorization = ExecutionRequest(invocationID:id,commandID:commandID,commandVersion:request.definitionVersion,toolID:contract?.execution.toolID ?? "keydock.workflow.step",toolVersion:contract?.execution.toolVersion ?? 1,caller:.workflow,callerInstanceID:request.runID.uuidString,resourceScope:scope,effects:[effect],actionID:contract?.action.toolID,actionVersion:contract?.action.toolVersion)
            let grant = PolicyGrant(caller:.workflow,callerInstanceID:request.runID.uuidString,commandID:commandID,commandVersion:request.definitionVersion,toolID:authorization.toolID,toolVersion:authorization.toolVersion,resourceScope:scope,allowedEffects:[effect],expiresAt:Date().addingTimeInterval(30),sideEffectsApproved:true,invocationID:id,actionID:authorization.actionID,actionVersion:authorization.actionVersion)
            try ExecutionPolicy.authorize(request:authorization,grant:grant)
            do { try await journal.begin(id:id,name:"Workflow step",commandID:"keydock.workflow-run."+request.runID.uuidString,commandVersion:request.definitionVersion,caller:"workflow",initialMessage:"workflow.stepIntent"); began = true }
            catch { await journal.abandonUndispatched(id); throw error }
            try Task.checkCancellation()
            dispatched = true
            let response: WorkflowHostResult
            switch request.operation {
            case .savedCommand(let commandID):
                _ = commandID
                let command = resolvedCommand!
                response = await withTaskCancellationHandler {
                    var output = "", result: ProcessResult?, exceeded = false
                    for await event in await runner.run(command,id:id) {
                        switch event {
                        case .started: break
                        case .output(let text,_):
                            if !exceeded && output.utf8.count+text.utf8.count <= TaskTextLimits.outputBytes { output += text }
                            else { exceeded = true; await runner.cancel(id) }
                        case .finished(let value): result = value
                        }
                        if Task.isCancelled { await runner.cancel(id) }
                    }
                    if Task.isCancelled { await runner.cancel(id) }
                    await runner.waitForCompletion(id)
                    return .init(outcome:result?.state == .interrupted || result == nil ? .unknown : (exceeded ? .failed : (Task.isCancelled || result?.state == .cancelled ? .cancelled : (result?.state == .succeeded ? .succeeded:.failed))),output:output)
                } onCancel: { Task { await runner.cancel(id) } }
            case .aiAction(let actionID):
                let ai = actions[actionID]!
                var usage = AIUsageAccumulator(), output = "", succeeded = false
                do {
                    for try await event in ai.provider.stream(.init(messages:[.init(role:"system",content:ai.action.prompt),.init(role:"user",content:request.input)],tools:[])) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let text): guard output.utf8.count+text.utf8.count <= TaskTextLimits.outputBytes else { throw AIProviderError.outputLimit }; output += text
                        case .usage(let value): try usage.observe(value)
                        case .toolCall: throw AIProviderError.unexpectedToolCall
                        case .completed: succeeded = true
                        }
                    }
                    try Task.checkCancellation()
                    guard succeeded, !output.isEmpty else { throw AIProviderError.truncatedStream }
                    response = .init(outcome:.succeeded,output:output)
                } catch { response = .init(outcome:Task.isCancelled ? .cancelled:.failed,output:output) }
                await onUsage(.init(id:id,endpoint:ai.provider.configuration.endpoint,model:ai.provider.configuration.model,usage:usage,outcome:response.outcome.rawValue))
            default: response = .init(outcome:.failed)
            }
            let state: ExecutionState = response.outcome == .succeeded ? .succeeded : (response.outcome == .cancelled ? .cancelled:(response.outcome == .unknown ? .interrupted:.failed))
            finishAttempted = true
            try await journal.finish(id:id,result:.init(state:state,message:"workflow.step."+response.outcome.rawValue))
            await journal.releaseProtection(for:id)
            return response
        } catch {
            if began {
                if !finishAttempted { try? await journal.finish(id:id,result:.init(state:dispatched ? .interrupted:.cancelled,message:dispatched ? "workflow.stepOutcomeUnknown":"workflow.stepNotDispatched")) }
                await journal.releaseProtection(for:id)
            }
            return .init(outcome:dispatched || finishAttempted ? .unknown : (Task.isCancelled ? .cancelled:.failed))
        }
    }
}
