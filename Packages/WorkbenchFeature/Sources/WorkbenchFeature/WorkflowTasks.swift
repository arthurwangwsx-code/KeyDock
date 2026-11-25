import Foundation
import AutomationCore
import AICore
import ExecutionCore

func workflowPhaseTitle(_ phase: WorkflowCheckpointPhase) -> String {
    switch phase { case .running: L("Running"); case .succeeded: L("Completed"); case .failed: L("Failed"); case .cancelled: L("Cancelled"); case .timedOut: L("Timed out"); case .unknown: L("Interrupted / unknown outcome") }
}

struct WorkflowScheduleAuthorization { let scheduleID:UUID; let revision:Int; let fingerprint:String }

public struct PendingWorkflowInput: Identifiable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let stepIndex: Int
    public let initialValue: String
}

extension WorkbenchModel {
    /// 专用工作流快捷键不需要原选区，跳过Launcher的通用目标捕获。
    public func performWorkflowShortcut(id: String) {
        guard !isShuttingDown else { return }
        launcherNoticeMessage = .none
        if id.hasPrefix("workflow."), let item = catalog.first(where: { $0.id == id && $0.kind == .utility && $0.payload == id }) {
            execute(item, caller: .shortcut)
        } else { launcherNoticeMessage = noticeKey("This saved workflow is no longer available.") }
        if !launcherNotice.isEmpty { workspaceNoticeMessage = launcherNoticeMessage; onOpenWorkspace?(.workflows) }
    }

    func launchSavedWorkflow(_ id: UUID) {
        guard !isShuttingDown else { return }
        guard let definition = configuration.workflows.first(where: { $0.id == id }) else {
            launcherNoticeMessage = noticeKey("This saved workflow is no longer available."); return
        }
        do {
            let plan = try compileWorkflow(definition)
            if definition.steps.contains(where:{ if case .savedCommand = $0.operation { true } else { false } }) { _ = try requireCommandContribution() }
            let commandsUsingInput = Set(configuration.savedCommands.filter { $0.arguments.contains("{{input}}") }.map(\.id))
            if plan.requiresInitialInput(commandsUsingInput: commandsUsingInput) { onOpenWorkspace?(.workflowInput(id)) }
            else if runWorkflow(definition, input: "") == nil { launcherNoticeMessage = noticeKey("Workflow could not start. Check its steps and AI configuration.") }
        } catch { launcherNoticeMessage = noticeKey("Workflow could not start. Check its steps and AI configuration.") }
    }

    @discardableResult public func removeWorkflow(_ id:UUID) -> Bool {
        workspaceNoticeMessage = noticeKey("Review this workflow in Workflows before removing it.")
        return false
    }

    @discardableResult public func saveWorkflow(_ definition: WorkflowDefinition) -> Bool {
        guard !isShuttingDown else { workspaceNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return false }
        do {
            _ = try compileWorkflow(definition)
            var next = configuration, value = definition
            value.version = (next.workflows.first(where:{$0.id == value.id})?.version ?? 0)+1
            if let index = next.workflows.firstIndex(where:{$0.id == value.id}) { next.workflows[index] = value }
            else { guard next.workflows.count < 32 else { throw WorkflowCompileError.tooManySteps }; next.workflows.append(value) }
            guard try JSONEncoder().encode(next).count <= 4*1_048_576 else { throw WorkflowCompileError.tooManySteps }
            return commitWorkspaceConfiguration(next)
        } catch { workspaceNoticeMessage = noticeKey("Workflow is invalid. Check names, inputs, references and budgets."); return false }
    }
    func compileWorkflow(_ definition: WorkflowDefinition, interaction: Bool = true) throws -> WorkflowPlan {
        guard Set(configuration.savedCommands.map(\.id)).count == configuration.savedCommands.count,
              Set(configuration.aiActions.map(\.id)).count == configuration.aiActions.count else { throw WorkflowCompileError.duplicateCatalogID }
        let plan = try WorkflowCompiler.compile(definition,availableCommandIDs:Set(configuration.savedCommands.map(\.id)),availableAIActionIDs:Set(configuration.aiActions.map(\.id)),allowsInteraction:interaction)
        for step in definition.steps {
            if case .savedCommand(let id) = step.operation {
                guard let command = configuration.savedCommands.first(where:{$0.id == id}), !command.interactive,
                      !(command.shellMode && command.arguments.contains("{{input}}")) else { throw WorkflowCompileError.missingCommand(id) }
                try command.validate()
                if !interaction && command.arguments.contains("{{input}}") { throw WorkflowCompileError.interactionNotAllowed(0) }
            }
        }
        return plan
    }
    @discardableResult public func runWorkflow(_ definition:WorkflowDefinition,input:String,interaction:Bool = true) -> UUID? {
        runWorkflow(definition,input:input,interaction:interaction,runID:UUID())
    }
    @discardableResult func runWorkflow(_ definition: WorkflowDefinition, input: String, interaction: Bool, runID id: UUID, scheduleAuthorization: WorkflowScheduleAuthorization? = nil, onFinished: (@MainActor (TaskStatus) async -> Void)? = nil) -> UUID? {
        do {
            guard !isShuttingDown, !executionReservations.contains(id), !tasks.contains(where:{$0.id == id}), input.utf8.count <= TaskTextLimits.inputBytes else { return nil }
            let plan = try compileWorkflow(definition,interaction:interaction)
            let referencedCommands = Set(definition.steps.compactMap { if case .savedCommand(let id) = $0.operation { id } else { nil as UUID? } })
            var commands: [UUID:PreparedWorkflowCommand] = [:]
            if !referencedCommands.isEmpty {
                let contract = try FrozenCommandContribution(requireCommandContribution())
                for command in configuration.savedCommands where referencedCommands.contains(command.id) { commands[command.id] = .init(command:command,contract:contract) }
            }
            let referencedAI = Set(definition.steps.compactMap { step -> UUID? in if case .aiAction(let id) = step.operation { id } else { nil } })
            var actions: [UUID:PreparedWorkflowAI] = [:]
            for action in configuration.aiActions where referencedAI.contains(action.id) { actions[action.id] = PreparedWorkflowAI(action:action,provider:try provider(override:action.modelOverride)) }
            let authorization: ExecutionRequest
            if let scheduleAuthorization {
                guard !interaction, scheduleAuthorization.fingerprint == (try scheduleFingerprint(definition.id)) else { throw ScheduleError.revisionConflict }
                let scope = ExecutionResourceScope.exact(namespace:"keydock.schedule",identifier:fingerprint(scheduleAuthorization.scheduleID.uuidString+"|"+String(scheduleAuthorization.revision)+"|"+scheduleAuthorization.fingerprint))
                authorization = ExecutionRequest(invocationID:id,commandID:"keydock.workflow."+definition.id.uuidString,commandVersion:definition.version,toolID:"keydock.schedule.workflow",toolVersion:1,caller:.workflow,callerInstanceID:scheduleAuthorization.scheduleID.uuidString,resourceScope:scope,effects:[.read])
                let grant = PolicyGrant(caller:.workflow,callerInstanceID:scheduleAuthorization.scheduleID.uuidString,commandID:authorization.commandID,commandVersion:definition.version,toolID:authorization.toolID,toolVersion:1,resourceScope:scope,allowedEffects:[.read],expiresAt:Date().addingTimeInterval(30),sideEffectsApproved:true,invocationID:id)
                try ExecutionPolicy.authorize(request:authorization,grant:grant)
            } else { authorization = try authorizeHostAction(id:"workflow."+definition.id.uuidString,operation:.navigate,resource:definition.id.uuidString+"|"+String(definition.version),invocation:id) }
            let draft = createDraft(input:input)
            guard ownsDraft(draft), reserveExecution(id,draft:draft) else { return nil }
            tasks.insert(RunningTaskItem(id:id,title:definition.name,state:.running,draftID:draft.id),at:0)
            tasks[0].receiptIsAI = true
            aiTaskIDs.insert(id); registerActivity(id,commandID:"workflow."+definition.id.uuidString,category:.workflow)
            let host = WorkflowExecutionHost(commands:commands,actions:actions,runner:processRunner,journal:agentToolStore,manual:{ [weak self] request in await self?.requestWorkflowInput(request) },onUsage:{ [weak self] value in
                await self?.recordUsage(id:value.id,endpoint:value.endpoint,model:value.model,purpose:"workflow."+definition.id.uuidString,observations:value.usage,outcome:value.outcome)
            },approve:{ [weak self] proposal in guard let self else { return false }; return try await self.requestApproval(proposal) })
            taskHandles[id] = Task { [weak self] in
                guard let self else { return }
                var started = false
                do {
                    try await beginAIReceipt(id:id,kind:.workflow,authorization:authorization); started = true
                    try Task.checkCancellation()
                    let result = await WorkflowRunner.run(plan,input:input,runID:id,host:{ request in try await host.invoke(request) },onCheckpoint:{ [weak self] checkpoint in
                        Task { @MainActor [weak self] in self?.publishWorkflowCheckpoint(checkpoint) }
                    })
                    await host.close(cancel:result.outcome != .succeeded)
                    if let checkpoint = result.checkpoints.last { publishWorkflowCheckpoint(checkpoint) }
                    let state: TaskStatus
                    switch result.outcome { case .succeeded: state = .completed; case .cancelled: state = .cancelled; case .timedOut: state = .timedOut; case .unknown: state = .interrupted; case .failed: state = .failed }
                    _ = appendOutput(id,text:result.output); updateTask(id,state:result.hasUncertainHostOutcome ? .interrupted:state,finished:true)
                    if result.hasUncertainHostOutcome, let index = tasks.firstIndex(where:{$0.id == id}) { tasks[index].noticeMessage = noticeKey("A workflow step may have effects. Check the result before starting a new run; nothing was replayed.") }
                } catch { await host.close(cancel:true); updateTask(id,state:Task.isCancelled ? .cancelled:.failed,finished:true) }
                cancelWorkflowInputs(runID:id)
                if started { await finishAIReceipt(id) }; await agentToolStore.releaseParentProtection(for:id); finishExecutionReservation(id)
                if let onFinished { await onFinished(tasks.first(where:{$0.id == id})?.status ?? .interrupted) }
            }
            if interaction { onOpenWorkspace?(.tasks(id)) }; return id
        } catch { workspaceNoticeMessage = noticeKey("Workflow could not start. Check its steps and AI configuration."); return nil }
    }
    func publishWorkflowCheckpoint(_ checkpoint: WorkflowCheckpoint) {
        guard !isShuttingDown, tasks.first(where:{$0.id == checkpoint.runID})?.isRunning == true,
              (workflowCheckpoints[checkpoint.runID]?.sequence ?? -1) < checkpoint.sequence else { return }
        workflowCheckpoints[checkpoint.runID] = checkpoint
    }
    func requestWorkflowInput(_ request: WorkflowHostRequest) async -> String? {
        guard request.allowsInteraction, !isShuttingDown, !Task.isCancelled else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isShuttingDown, !cancelledTaskIDs.contains(request.runID) else { continuation.resume(returning:nil); return }
                pendingWorkflowInputs.append(.init(id:id,runID:request.runID,stepIndex:request.stepIndex,initialValue:request.input)); workflowInputContinuations[id] = continuation
                updateTask(request.runID,state:.awaitingApproval)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.resolveWorkflowInput(id,value:nil) } }
    }
    public func resolveWorkflowInput(_ id: UUID,value: String?) {
        guard let request = pendingWorkflowInputs.first(where:{$0.id == id}) else { return }
        pendingWorkflowInputs.removeAll{$0.id == id}
        let permitted = !isShuttingDown && !cancelledTaskIDs.contains(request.runID) && tasks.first(where:{$0.id == request.runID})?.canCancel == true && (value?.utf8.count ?? 0) <= TaskTextLimits.inputBytes
        if tasks.first(where:{$0.id == request.runID})?.isRunning == true { updateTask(request.runID,state:.running) }
        workflowInputContinuations.removeValue(forKey:id)?.resume(returning:permitted ? value:nil)
    }
    func cancelWorkflowInputs(runID: UUID) { for id in pendingWorkflowInputs.filter({$0.runID == runID}).map(\.id) { resolveWorkflowInput(id,value:nil) } }
}
