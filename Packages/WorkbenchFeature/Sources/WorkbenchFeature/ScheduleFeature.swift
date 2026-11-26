import Foundation
import AutomationCore
import AICore

extension WorkbenchModel {
    /// 授权绑定完整定义、命令实参和AI目标。任何引用编辑均需重新批准；密钥不进入摘要或指纹。
    func scheduleFingerprint(_ workflowID:UUID) throws -> String {
        guard let workflow = configuration.workflows.first(where:{$0.id == workflowID}) else { throw ScheduleError.notFound }
        _ = try compileWorkflow(workflow,interaction:false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var parts = [String(decoding:try encoder.encode(workflow),as:UTF8.self)]
        for step in workflow.steps {
            switch step.operation {
            case .savedCommand(let id):
                guard let value = configuration.savedCommands.first(where:{$0.id == id}) else { throw ScheduleError.notFound }
                parts.append(try installedCommandContribution().fingerprint(value))
            case .aiAction(let id):
                guard let value = configuration.aiActions.first(where:{$0.id == id}) else { throw ScheduleError.notFound }
                guard let endpoint = URL(string:configuration.endpoint) else { throw ScheduleError.invalidDefinition }
                try AIProviderConfiguration(endpoint:endpoint,model:value.modelOverride.isEmpty ? configuration.model:value.modelOverride,allowsLocalHTTP:configuration.localHTTP,tokenLimitParameter:TokenLimitParameter(rawValue:configuration.tokenLimitParameter) ?? .maxCompletionTokens).validate()
                parts.append(String(decoding:try encoder.encode(value),as:UTF8.self))
                parts.append(configuration.endpoint); parts.append(configuration.model); parts.append(String(configuration.localHTTP)); parts.append(configuration.tokenLimitParameter)
            default: break
            }
        }
        return fingerprint(parts.joined(separator:"\u{0}"))
    }
    func scheduleReview(_ workflowID:UUID) -> String {
        guard let workflow = configuration.workflows.first(where:{$0.id == workflowID}) else { return "" }
        var lines = [workflow.name]
        for step in workflow.steps {
            switch step.operation {
            case .savedCommand(let id): if let command = configuration.savedCommands.first(where:{$0.id == id}) { lines.append(command.executable + "\n" + command.arguments.joined(separator:"\n") + "\n" + command.workingDirectory) }
            case .aiAction(let id): if let action = configuration.aiActions.first(where:{$0.id == id}) { lines.append(action.displayName+"\n"+configuration.endpoint+"\n"+(action.modelOverride.isEmpty ? configuration.model:action.modelOverride)) }
            default: break
            }
        }
        return lines.joined(separator:"\n\n")
    }
    func startSchedules() {
        guard !isDesktopReview,!isShuttingDown,scheduleTimer == nil,schedules.contains(where:{$0.definition.enabled}) else { return }
        scheduleTimer = Task { [weak self] in
            defer { self?.scheduleTimer = nil }
            while !Task.isCancelled {
                await self?.tickSchedules()
                guard self?.schedules.contains(where:{$0.definition.enabled}) == true else { return }
                do { try await Task.sleep(for:.seconds(5)) } catch { return }
            }
        }
    }
    func tickSchedules() async {
        guard let owner = beginScheduleMutation() else { return }; defer { finishScheduleMutation(owner) }
        do {
            let snapshot = await scheduleLedger.snapshots()
            var allowed: Set<UUID> = [], allowedSchedules: Set<UUID> = []
            for value in snapshot where value.definition.enabled && !scheduleSuspended.contains(value.id) {
                let current = try? scheduleFingerprint(value.definition.workflowID)
                if let current, current == value.definition.authorizationFingerprint { allowed.insert(value.definition.workflowID); allowedSchedules.insert(value.id) }
                else {
                    scheduleSuspended.insert(value.id)
                    if let run = value.activeAttempt?.id { cancelTask(run) }
                    _ = try? await scheduleLedger.setEnabled(false,id:value.id,expectedRevision:value.definition.revision,now:Date())
                    workspaceNoticeMessage = noticeKey("A schedule was paused because its workflow, command or AI target changed. Review it before enabling again.")
                }
            }
            let free = max(0,sessionLimits.activeTasks-executionReservations.count)
            if free > 0 {
                let claims = try await scheduleLedger.claimDue(now:Date(),availableWorkflowIDs:Set(configuration.workflows.map(\.id)),unattendedWorkflowIDs:allowed,authorizedScheduleIDs:allowedSchedules,limit:min(8,free))
                for claim in claims {
                    guard !isShuttingDown else { _ = try? await scheduleLedger.complete(attemptID:claim.id,outcome:.cancelled,now:Date()); continue }
                    let records = await scheduleLedger.snapshots()
                    guard let value = records.first(where:{$0.id == claim.scheduleID}), value.activeAttempt?.id == claim.id,
                          value.definition.enabled, !scheduleSuspended.contains(value.id), value.definition.authorizationFingerprint == (try? scheduleFingerprint(claim.workflowID)),
                          let approved = value.definition.authorizationFingerprint, let workflow = configuration.workflows.first(where:{$0.id == claim.workflowID}) else {
                        _ = try await scheduleLedger.complete(attemptID:claim.id,outcome:.cancelled,now:Date()); continue
                    }
                    scheduledRuns[claim.id] = claim.scheduleID
                    let run = runWorkflow(workflow,input:"",interaction:false,runID:claim.id,scheduleAuthorization:.init(scheduleID:value.id,revision:value.definition.revision,fingerprint:approved),onFinished:{ [weak self] state in await self?.finishScheduledRun(claim.id,state:state) })
                    if run == nil { await finishScheduledRun(claim.id,state:.failed) }
                }
            }
            schedules = await scheduleLedger.snapshots()
        } catch { workspaceNoticeMessage = noticeKey("Schedule storage failed. No failed schedule is automatically retried.") }
    }
    private func finishScheduledRun(_ id:UUID,state:TaskStatus) async {
        scheduledRuns.removeValue(forKey:id)
        let outcome: ScheduleAttemptOutcome = switch state { case .completed: .succeeded; case .cancelled: .cancelled; case .interrupted,.timedOut: .unknown; default: .failed }
        do { _ = try await scheduleLedger.complete(attemptID:id,outcome:outcome,now:Date()); schedules = await scheduleLedger.snapshots() }
        catch { workspaceNoticeMessage = noticeKey("Schedule completion could not be saved. Check the run before enabling it again.") }
    }
    func editSchedule(_ value:ScheduleSnapshot,name:String,workflowID:UUID,trigger:ScheduleTrigger) async {
        guard configuration.workflows.contains(where:{$0.id == workflowID}), let owner = beginScheduleMutation() else { return }
        scheduleSuspended.insert(value.id); defer { finishScheduleMutation(owner) }
        do {
            let changed = try await scheduleLedger.upsert(.init(id:value.id,name:name,workflowID:workflowID,enabled:false,trigger:trigger,revision:value.definition.revision+1),now:Date())
            if let run = changed.invalidatedAttemptID { cancelTask(run) }
            schedules = await scheduleLedger.snapshots()
        } catch { workspaceNoticeMessage = noticeKey("Schedule could not be changed. It remains paused for this session; check saved settings before restarting.") }
    }
    func addSchedule(name:String,workflowID:UUID,trigger:ScheduleTrigger) async {
        guard configuration.workflows.contains(where:{$0.id == workflowID}), let owner = beginScheduleMutation() else { return }
        defer { finishScheduleMutation(owner) }
        do { _ = try await scheduleLedger.upsert(.init(name:name,workflowID:workflowID,trigger:trigger),now:Date()); schedules = await scheduleLedger.snapshots() }
        catch { workspaceNoticeMessage = noticeKey("Schedule could not be saved. Check its name, time zone and interval.") }
    }
    func setSchedule(_ value:ScheduleSnapshot,enabled:Bool,approvedFingerprint:String? = nil) async {
        guard let owner = beginScheduleMutation() else { return }
        defer { finishScheduleMutation(owner) }
        if !enabled { scheduleSuspended.insert(value.id); if let id = value.activeAttempt?.id { cancelTask(id) } }
        do {
            let old = value.definition
            if enabled { guard let approvedFingerprint, approvedFingerprint == (try scheduleFingerprint(old.workflowID)), !value.reviewRequired else { throw ScheduleError.revisionConflict } }
            let next = ScheduleDefinition(id:old.id,name:old.name,workflowID:old.workflowID,enabled:enabled,trigger:old.trigger,revision:old.revision+1,authorizationFingerprint:enabled ? approvedFingerprint:old.authorizationFingerprint)
            let mutation = try await scheduleLedger.upsert(next,now:Date())
            if let id = mutation.invalidatedAttemptID { cancelTask(id) }
            if enabled { scheduleSuspended.remove(value.id) }; schedules = await scheduleLedger.snapshots()
            if enabled { startSchedules() }
        } catch { workspaceNoticeMessage = noticeKey("Schedule could not be changed. It remains paused for this session; check saved settings before restarting.") }
    }
    func acknowledgeSchedule(_ value:ScheduleSnapshot) async {
        guard let owner = beginScheduleMutation() else { return }; defer { finishScheduleMutation(owner) }
        do { _ = try await scheduleLedger.acknowledgeUnknown(id:value.id,expectedRevision:value.definition.revision,now:Date()); schedules = await scheduleLedger.snapshots() }
        catch { workspaceNoticeMessage = noticeKey("Schedule could not be changed. Check its current revision.") }
    }
    func removeSchedule(_ value:ScheduleSnapshot) async {
        guard let owner = beginScheduleMutation() else { return }; defer { finishScheduleMutation(owner) }
        scheduleSuspended.insert(value.id); if let id = value.activeAttempt?.id { cancelTask(id) }
        do { if let id = try await scheduleLedger.remove(id:value.id,expectedRevision:value.definition.revision) { cancelTask(id) }; schedules = await scheduleLedger.snapshots() }
        catch { workspaceNoticeMessage = noticeKey("Schedule could not be changed. It remains paused for this session; check saved settings before restarting.") }
    }
}
