import Foundation
import AgentCore
import AICore
import ExecutionCore

extension WorkbenchModel {
    @discardableResult public func removeAgent(_ id:UUID) -> Bool {
        var next = configuration; next.agents.removeAll{$0.id == id}; return commitSettingsConfiguration(next)
    }

    @discardableResult public func saveAgent(_ value: AgentDefinition) -> Bool {
        guard !isShuttingDown else { return false }
        do {
            var next = configuration, agent = value
            try agent.validate()
            agent.version = (next.agents.first { $0.id == agent.id }?.version ?? 0) + 1
            if let index = next.agents.firstIndex(where:{ $0.id == agent.id }) { next.agents[index] = agent }
            else { guard next.agents.count < 32 else { throw AgentToolError.invalidDefinition }; next.agents.append(agent) }
            return commitSettingsConfiguration(next)
        } catch { workspaceNoticeMessage = noticeKey("Agent configuration is invalid"); return false }
    }

    @discardableResult public func runAgent(_ definition: AgentDefinition, input: String) -> UUID? {
        let id = UUID()
        do {
            guard !isShuttingDown, !input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  input.utf8.count <= TaskTextLimits.inputBytes else { throw AIProviderError.invalidRequest }
            try definition.validate()
            guard Set(configuration.savedCommands.map(\.id)).count == configuration.savedCommands.count else { throw AgentToolError.invalidDefinition }
            let service = try provider(override:definition.modelOverride)
            let authorization = try authorizeHostAction(id:"agent."+definition.id.uuidString,operation:.runAgent,resource:service.configuration.endpoint.absoluteString+"|"+input,availableContext:[.explicitInput],modelOverride:definition.modelOverride,invocation:id)
            let selected = configuration.savedCommands.filter { definition.allowedCommandIDs.contains($0.id) }
            let sources = configuration.mcpServers.filter { definition.allowedMCPServerIDs.contains($0.id) && $0.enabled && !mcpSessionDisabled.contains($0.id) }
            guard Set(selected.map(\.id)) == definition.allowedCommandIDs, Set(sources.map(\.id)) == definition.allowedMCPServerIDs else { throw AgentToolError.invalidDefinition }
            let time = CurrentTimeTool()
            var initialTools = [ScopedAITool(definition:time.definition,effects:[.read],resource:.none,approvalSummary:"") { arguments,_ in try await time.call(arguments:arguments) }]
            for command in selected { initialTools.append(try SavedCommandAITool.make(command:command,resourceFingerprint:fingerprint(command),runner:processRunner)) }
            let frozenTools = initialTools
            let draft = createDraft(input:input)
            guard ownsDraft(draft), reserveExecution(id,draft:draft) else { return nil }
            draft.latestRunID = id; agentRunDefinitions[id] = definition
            tasks.insert(RunningTaskItem(id:id,title:definition.name,state:.running,draftID:draft.id,modelName:service.configuration.model),at:0)
            tasks[0].aiUsageSummary = .pending; aiTaskIDs.insert(id)
            registerActivity(id,commandID:"agent."+definition.id.uuidString,category:.agent)
            taskHandles[id] = Task { [weak self] in
                guard let self else { return }
                let deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for:.seconds(definition.timeoutSeconds)) } catch { return }
                    guard let self,!isShuttingDown,!cancelledTaskIDs.contains(id),tasks.first(where:{$0.id == id})?.canCancel == true else { return }
                    timedOutTaskIDs.insert(id); cancelTask(id)
                }
                defer { deadline.cancel() }
                var usage = AIUsageAccumulator(), outcome = "failed", started = false
                var broker: ScopedToolBroker?
                do {
                    try await beginAIReceipt(id:id,kind:.agent,authorization:authorization); started = true
                    let mcpTools = try await prepareMCPTools(definition,sources:sources,runID:id)
                    try Task.checkCancellation()
                    let tools = frozenTools+mcpTools
                    let routing = try ScopedToolBroker(runID:id,tools:tools,journal:agentToolStore) { [weak self] proposal in guard let self else { return false }; return try await self.requestApproval(proposal) }
                    broker = routing
                    let runner = BoundedAgentRunner(provider:service,broker:routing,maxToolCalls:definition.maxToolCalls,maxTurns:definition.maxTurns,wallTimeout:.seconds(definition.timeoutSeconds),maxOutputBytes:TaskTextLimits.outputBytes)
                    for try await event in runner.run(messages:[.init(role:"system",content:definition.instructions),.init(role:"user",content:input)],allowedTools:Set(tools.map{$0.definition.name})) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let text): try appendAIOutput(id,text:text)
                        case .toolStarted(let call): try appendAIOutput(id,text:"\n["+call.name+"]\n")
                        case .toolFinished(_,let result): try appendAIOutput(id,text:result+"\n")
                        case .usage(let value): mergeUsage(value,into:&usage,id:id)
                        case .usageUnknown(let attempt): usage.markUnknown(attemptID:attempt)
                        case .completed: break
                        }
                    }
                    try Task.checkCancellation(); await routing.close(cancel:false); await closeMCPRun(id)
                    try Task.checkCancellation()
                    guard !isShuttingDown,!cancelledTaskIDs.contains(id),!timedOutTaskIDs.contains(id) else { throw CancellationError() }
                    outcome = "succeeded"; updateTask(id,state:.completed,finished:true)
                } catch {
                    await broker?.close(cancel:true); await closeMCPRun(id)
                    markIncompleteAIError(error,id:id)
                    let uncertain = (await broker?.unknownInvocationCount() ?? 0) > 0 || error is MCPSetupError || (error as? AgentToolError) == .receiptUnavailable
                    let cancelled = Task.isCancelled || error is CancellationError
                    let budget = (error as? AIProviderError) == .toolBudgetExceeded
                    let state: TaskStatus = uncertain ? .interrupted : (pausedAgentIDs.contains(id) || budget ? .paused : (timedOutTaskIDs.contains(id) ? .timedOut : (cancelled ? .cancelled:.failed)))
                    outcome = state == .paused ? "paused" : (uncertain ? "interrupted" : (state == .timedOut ? "timedOut" : (cancelled ? "cancelled":"failed")))
                    updateTask(id,state:state,finished:true)
                    if let index = tasks.firstIndex(where:{$0.id == id}) {
                        if uncertain { tasks[index].noticeMessage = noticeKey("A tool may have effects. Check the result before starting a new run; nothing was replayed.") }
                        else if state == .paused { tasks[index].noticeMessage = noticeKey("Agent paused. A new attempt rechecks scope and may repeat completed work; nothing resumes automatically.") }
                        else if !cancelled { tasks[index].noticeMessage = error as? AgentToolError == .denied ? noticeKey("Tool call was denied. No further step was run.") : aiErrorNotice(error) }
                    }
                }
                cancelApprovals(runID:id)
                await recordUsage(id:id,endpoint:service.configuration.endpoint,model:service.configuration.model,purpose:"agent."+definition.id.uuidString,observations:usage,outcome:outcome)
                if started { await finishAIReceipt(id) }; await agentToolStore.releaseParentProtection(for:id); finishExecutionReservation(id)
            }
            onOpenWorkspace?(.tasks(id)); return id
        } catch { workspaceNoticeMessage = aiErrorNotice(error); return nil }
    }
    public func pauseAgent(_ id: UUID) {
        guard agentRunDefinitions[id] != nil,tasks.first(where:{$0.id == id})?.canCancel == true else { return }
        pausedAgentIDs.insert(id); cancelTask(id)
    }
    public func restartAgent(_ id: UUID) {
        guard let definition = agentRunDefinitions[id],let task = tasks.first(where:{$0.id == id}),!task.isRunning,let draftID = task.draftID,let draft = drafts[draftID] else { return }
        _ = runAgent(definition,input:draft.input)
    }

    func requestApproval(_ proposal: AgentToolApproval) async throws -> Bool {
        guard !isShuttingDown, !Task.isCancelled, tasks.first(where:{$0.id == proposal.runID})?.canCancel == true else { throw CancellationError() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isShuttingDown, !cancelledTaskIDs.contains(proposal.runID) else { continuation.resume(returning:false); return }
                pendingApprovals.append(proposal); approvalContinuations[proposal.id] = continuation
                updateTask(proposal.runID,state:.awaitingApproval)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolveApproval(proposal.id,approved:false) } }
    }
    public func resolveApproval(_ id: UUID, approved: Bool) {
        guard let proposal = pendingApprovals.first(where:{$0.id == id}) else { return }
        pendingApprovals.removeAll { $0.id == id }
        let permitted = approved && !isShuttingDown && !cancelledTaskIDs.contains(proposal.runID) && tasks.first(where:{$0.id == proposal.runID})?.canCancel == true
        if tasks.first(where:{$0.id == proposal.runID})?.isRunning == true { updateTask(proposal.runID,state:.running) }
        approvalContinuations.removeValue(forKey:id)?.resume(returning:permitted)
    }
    func cancelApprovals(runID: UUID) {
        for id in pendingApprovals.filter({$0.runID == runID}).map(\.id) { resolveApproval(id,approved:false) }
    }
}
