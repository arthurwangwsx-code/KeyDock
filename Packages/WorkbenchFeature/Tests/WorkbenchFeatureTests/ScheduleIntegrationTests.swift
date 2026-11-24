import Foundation
import Testing
import AutomationCore
import ExecutionCore
@testable import WorkbenchFeature

enum ScheduleReferenceMutation: String, CaseIterable, Sendable { case command, workflow }

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ScheduleIntegrationTests {
    @Test(arguments: ScheduleReferenceMutation.allCases)
    func changedReferenceFingerprintPausesDueScheduleBeforeDispatch(_ mutation: ScheduleReferenceMutation) async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let originalMarker = fixture.directory.appendingPathComponent("original-plan-must-not-run")
            let changedMarker = fixture.directory.appendingPathComponent("changed-plan-must-not-run")
            var command = SavedCommand(name: "Synthetic scheduled marker", executable: "/usr/bin/touch", arguments: [originalMarker.path], workingDirectory: fixture.directory.path)
            var workflow = WorkflowDefinition(name: "Synthetic scheduled workflow", steps: [.init(operation: .savedCommand(command.id))])
            store.configuration.savedCommands = [command]; store.configuration.workflows = [workflow]
            let approved = try store.scheduleFingerprint(workflow.id)
            let schedule = ScheduleDefinition(name: "Synthetic due schedule", workflowID: workflow.id, enabled: true,
                trigger: .interval(seconds: 60), authorizationFingerprint: approved)
            // 过去锚点使生产tick立即到期，不用等待真实分钟，也不修改系统时间。
            try await store.scheduleLedger.upsert(schedule, now: Date(timeIntervalSince1970: 1_700_000_000))
            switch mutation {
            case .command: command.arguments = [changedMarker.path]; store.configuration.savedCommands = [command]
            case .workflow: workflow.version += 1; workflow.steps.append(.init(operation: .transform(.trim), input: .previousOutput)); store.configuration.workflows = [workflow]
            }
            let current = try store.scheduleFingerprint(workflow.id)
            #expect(current != approved)
            await store.tickSchedules()
            let records = await store.scheduleLedger.snapshots()
            let paused = try #require(records.first { $0.id == schedule.id })
            #expect(!paused.definition.enabled && paused.activeAttempt == nil && paused.lastAttempt == nil)
            #expect(store.scheduleSuspended.contains(schedule.id) && !store.scheduleBusy)
            await fixture.assertNoExecution(markers: [originalMarker, changedMarker])
        }
    }

    @Test func failedDurableClaimCreatesNeitherTaskNorProcessAndDoesNotAdvanceThePlan() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, manager = FileManager.default
            let marker = fixture.directory.appendingPathComponent("failed-claim-must-not-run")
            let command = SavedCommand(name: "Synthetic claim failure marker", executable: "/usr/bin/touch", arguments: [marker.path], workingDirectory: fixture.directory.path)
            let workflow = WorkflowDefinition(name: "Synthetic claim failure workflow", steps: [.init(operation: .savedCommand(command.id))])
            store.configuration.savedCommands = [command]; store.configuration.workflows = [workflow]
            let authorization = try store.scheduleFingerprint(workflow.id)
            let definition = ScheduleDefinition(name: "Synthetic unwritable due schedule", workflowID: workflow.id, enabled: true,
                trigger: .interval(seconds: 60), authorizationFingerprint: authorization)
            let mutation = try await store.scheduleLedger.upsert(definition, now: Date(timeIntervalSince1970: 1_700_000_000))
            let saved = mutation.snapshot
            let target = fixture.directory.appendingPathComponent("schedules/scheduled-workflows.json")
            let original = try Data(contentsOf: target)
            // 仅替换自有JSON目标为目录，真实触发私有持久化adapter拒绝写入；不依赖chmod/root行为。
            try manager.removeItem(at: target)
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: target); try? original.write(to: target) }
            await store.tickSchedules()
            await store.tickSchedules()
            let records = await store.scheduleLedger.snapshots()
            let retained = try #require(records.first { $0.id == definition.id })
            #expect(retained == saved && retained.activeAttempt == nil && retained.lastClaimedKey == nil)
            #expect(!store.workspaceNotice.isEmpty && !store.scheduleBusy)
            await fixture.assertNoExecution(markers: [marker])
            let directoryValues = try target.resourceValues(forKeys: [.isDirectoryKey])
            #expect(directoryValues.isDirectory == true)
        }
    }

    @Test func enablingDynamicWorkflowScheduleFailsBeforeClaimOrApproval() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, marker = fixture.directory.appendingPathComponent("dynamic-schedule-must-not-run")
            let command = SavedCommand(name: "Synthetic schedule dynamic refusal", executable: "/usr/bin/touch", arguments: ["{{input}}"], workingDirectory: fixture.directory.path)
            let workflow = WorkflowDefinition(name: "Synthetic dynamic scheduled workflow", steps: [.init(operation: .savedCommand(command.id), input: .literal(marker.path))])
            store.configuration.savedCommands = [command]; store.configuration.workflows = [workflow]
            let definition = ScheduleDefinition(name: "Synthetic disabled dynamic schedule", workflowID: workflow.id, trigger: .interval(seconds: 60))
            let mutation = try await store.scheduleLedger.upsert(definition, now: Date(timeIntervalSince1970: 1_700_000_000))
            let disabled = mutation.snapshot
            await store.setSchedule(disabled, enabled: true, approvedFingerprint: "synthetic-untrusted-fingerprint")
            await store.tickSchedules()
            let records = await store.scheduleLedger.snapshots()
            let retained = try #require(records.first { $0.id == definition.id })
            #expect(!retained.definition.enabled && retained.definition.revision == 1 && retained.activeAttempt == nil)
            await fixture.assertNoExecution(markers: [marker])
        }
    }
}

extension ScheduleIntegrationTests {
    @Test func approvedDueWorkflowRunsOnceWithItsClaimIdentityAndWorkflowCaller() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name:"Synthetic scheduled printf",executable:"/usr/bin/printf",arguments:["%s","scheduled result"],workingDirectory:fixture.directory.path)
            let workflow = WorkflowDefinition(name:"Synthetic approved schedule",steps:[.init(operation:.savedCommand(command.id))])
            store.configuration.savedCommands = [command]; store.configuration.workflows = [workflow]
            let definition = ScheduleDefinition(name:"Synthetic approved plan",workflowID:workflow.id,enabled:true,trigger:.interval(seconds:60),authorizationFingerprint:try store.scheduleFingerprint(workflow.id))
            try await store.scheduleLedger.upsert(definition,now:Date(timeIntervalSince1970:1_700_000_000))
            await store.tickSchedules()
            let record = try #require(await store.scheduleLedger.snapshots().first)
            let attempt = try #require(record.activeAttempt ?? record.lastAttempt)
            try await fixture.drain(attempt.id)
            try await fixture.eventually { store.schedules.first?.lastAttempt?.id == attempt.id }
            let result = try fixture.task(attempt.id)
            #expect(result.status == .completed && result.output == "scheduled result")
            let parent = try #require(await store.aiInvocationStore.list().first{$0.id == attempt.id})
            #expect(parent.caller == "workflow" && parent.state == .succeeded)
            await store.tickSchedules()
            #expect(store.tasks.count == 1 && store.pendingApprovals.isEmpty)
            #expect(store.schedules.first?.lastAttempt?.outcome == .succeeded)
        }
    }
}
