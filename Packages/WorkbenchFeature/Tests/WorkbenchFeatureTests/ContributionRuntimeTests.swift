import Foundation
import Combine
import Testing
import CommandCore
import ExecutionCore
import AgentCore
import AutomationCore
@testable import WorkbenchFeature

@Suite(.serialized,.timeLimit(.minutes(1))) @MainActor struct ContributionRuntimeTests {
    @Test func pendingShortcutCannotAdoptEditedAIInstructionsOrInputPolicy() async throws {
        try await withStoreHTTPFixture(path:"stream") { fixture in
            let store = fixture.store
            let pending = try #require(store.prepareShortcutInvocation(id:"ai."+fixture.action.id.uuidString))
            store.configuration.aiActions[0].prompt = "Synthetic edited instructions"
            store.configuration.aiActions[0].input = .clipboard; store.rebuildCatalog()
            store.performCommand(pending)
            #expect(store.drafts.isEmpty && store.tasks.isEmpty && !store.launcherNotice.isEmpty)
            let stats = try await fixture.server.stats(); #expect(stats["post_requests"] == 0)
        }
    }
    @Test func launcherAndToolsUseTheSameCalculatorAndOnlySelectionCopies() async throws {
        var writes: [String] = []
        try await withStoreHTTPFixture(path:"stream",clipboardWriter:{ writes.append($0) }) { fixture in
            let store = fixture.store, launcher = LauncherSession(store:fixture.store)
            launcher.setVisible(true); launcher.query = "2+3"
            try await storeEventually { launcher.resultBatch?.isComplete == true }
            let item = try #require(launcher.results.first(where:{$0.id == "utility.calculator.result"}))
            #expect(store.launcherPrimaryActionTitle(for: item) == L("Copy calculated result"))
            let fileBinding = try store.contributionSnapshot.binding(for: BuiltinContributionID.files)
            let file = CommandItem(id: "file.synthetic", title: "Synthetic file", kind: .utility, payload: "file.synthetic", contribution: fileBinding)
            #expect(store.launcherPrimaryActionTitle(for: file) == L("Reveal in Finder"))
            #expect(item.title == (try store.calculate(.expression("2+3"))) && writes.isEmpty)
            let plan = try store.contributions.queryPlan(configuration:store.configuration,snapshot:store.contributionSnapshot,files:nil)
            let source = try #require(plan.sources[BuiltinContributionID.calculator])
            let converted = try #require(try await source.provider.commands(matching:"10 km to mi").first)
            #expect(converted.title == (try store.calculate(.conversion("10 km to mi"))))
            // Startup recovery may rebuild the same catalog between displaying a result and Return.
            var catalogChanges = 0
            let observation = store.$catalog.dropFirst().sink { _ in catalogChanges += 1 }
            store.rebuildCatalog()
            #expect(catalogChanges == 0)
            defer { observation.cancel() }
            launcher.selectedID = item.id; launcher.execute()
            try await storeEventually { store.contributionActionTasks.isEmpty }
            #expect(writes == ["5"])
            var forged = item; forged.payload = "calculate.arbitrary text"
            store.execute(forged); store.execute(item,caller:.agent)
            #expect(writes == ["5"] && store.tasks.isEmpty)
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.calculator))
            #expect(store.launcherPrimaryActionTitle(for: item) == L("Unavailable"))
            #expect(store.setContributionEnabled(true,id:BuiltinContributionID.calculator))
            store.execute(item)
            #expect(writes == ["5"])
            let syntheticWindow = CommandItem(id: "window.synthetic", title: "Synthetic window", kind: .window)
            let beforeRefresh = catalogChanges
            store.rebuildCatalog(windows: [syntheticWindow])
            #expect(catalogChanges == beforeRefresh + 1)
            store.rebuildCatalog()
            #expect(catalogChanges == beforeRefresh + 1)
            var renamed = syntheticWindow
            renamed.title = "Renamed synthetic window"
            store.rebuildCatalog(windows: [renamed])
            #expect(catalogChanges == beforeRefresh + 2)
            let stats = try await fixture.server.stats(); #expect(stats["post_requests"] == 0)
        }
    }

    @Test func failedUserCopyStillSupersedesDelayedAIAutoCopy() async throws {
        var writes: [String] = []
        try await withStoreHTTPFixture(path:"held-text",clipboardWriter:{ value in writes.append(value); throw CocoaError(.fileWriteUnknown) }) { fixture in
            let store = fixture.store
            var action = fixture.action; action.output = .copy
            let draft = store.createDraft(input:"Synthetic delayed input")
            let id = try #require(store.runAI(action:action,draft:draft))
            try await storeEventually { try await fixture.server.stats()["held_text_started"] == 1 }
            let plan = try store.contributions.queryPlan(configuration:store.configuration,snapshot:store.contributionSnapshot,files:nil)
            let source = try #require(plan.sources[BuiltinContributionID.calculator])
            let item = try #require(try await source.provider.commands(matching:"2+3").first)
            store.execute(item)
            #expect(store.latestAutoCopyRunID == nil && writes == ["5"])
            let (_,response) = try await URLSession.shared.data(from:fixture.server.baseURL.appendingPathComponent("release-text"))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            try await fixture.drain(id)
            #expect(writes == ["5"] && store.tasks.first(where:{$0.id == id})?.status == .completed)
        }
    }

    @Test func oneCLIAdmissionKeepsFrozenArgumentsWhileOldResultsAndHotkeysExpire() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            var command = SavedCommand(name:"Synthetic frozen command",executable:"/usr/bin/printf",arguments:["%s","original"],workingDirectory:fixture.directory.path)
            store.configuration.savedCommands = [command]; store.rebuildCatalog()
            let item = try #require(store.catalog.first(where:{$0.kind == .command}))
            let pending = try #require(store.prepareShortcutInvocation(id:item.id))
            store.execute(item)
            let id = try #require(store.tasks.first?.id)
            #expect(store.tasks.count == 1 && store.executionReservations == [id])
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            command.arguments = ["%s","changed"]; store.configuration.savedCommands = [command]; store.rebuildCatalog()
            try await fixture.drain(id)
            #expect(try fixture.task(id).output == "original")
            let receipts = await store.invocationStore.list()
            #expect(receipts.count == 1 && receipts.first?.state == .succeeded)
            #expect(!store.isCollectionActionEnabled(item.id) && store.collectionAction(item.id)?.title == command.name)
            #expect(store.saveCollection(id:nil,name:"Synthetic disabled references",commandIDs:[item.id]))
            #expect(store.setContributionEnabled(true,id:BuiltinContributionID.commands))
            store.performCommand(pending); store.execute(item)
            #expect(store.tasks.count == 1)
            let next = try #require(store.runCommand(command,showWorkspace:true)); try await fixture.drain(next)
            #expect(try fixture.task(next).output == "changed")
            let after = await store.invocationStore.list()
            #expect(store.tasks.count == 2 && after.count == 2)
        }
    }

    @Test func failedCLIIntentDoesNotLaunchAProcess() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, marker = fixture.directory.appendingPathComponent("must-not-exist")
            let index = fixture.directory.appendingPathComponent("invocations/invocations.json")
            if FileManager.default.fileExists(atPath:index.path) { try FileManager.default.moveItem(at:index,to:fixture.directory.appendingPathComponent("owned-index-backup")) }
            try FileManager.default.createDirectory(at:index,withIntermediateDirectories:false)
            let command = SavedCommand(name:"Synthetic blocked intent",executable:"/usr/bin/touch",arguments:[marker.path],workingDirectory:fixture.directory.path)
            let id = try #require(store.runCommand(command)); try await fixture.drain(id)
            #expect(try fixture.task(id).status == .failed)
            #expect(!FileManager.default.fileExists(atPath:marker.path) && store.executionReservations.isEmpty)
        }
    }

    @Test func disabledCommandsRejectNewWorkflowAndAgentBeforeCredentialReadButKeepDefinitionsEditable() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name:"Synthetic command",executable:"/usr/bin/printf",arguments:["%s","kept"],workingDirectory:fixture.directory.path)
            store.configuration.savedCommands = [command]
            let workflow = WorkflowDefinition(name:"Synthetic saved workflow",steps:[.init(operation:.savedCommand(command.id))])
            var agent = AgentDefinition(); agent.name = "Synthetic saved agent"; agent.allowedCommandIDs = [command.id]
            // 配置为Keychain路径；fixture的credentialReader一旦调用即记录失败。
            store.configuration.endpoint = "https://synthetic.invalid/v1/chat/completions"; store.configuration.model = "synthetic-model"
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            #expect(store.saveWorkflow(workflow) && store.saveAgent(agent))
            #expect(store.runWorkflow(workflow,input:"synthetic") == nil)
            #expect(store.runAgent(agent,input:"synthetic") == nil)
            await fixture.assertNoExecution()
            let pure = WorkflowDefinition(name:"Synthetic text only",steps:[.init(operation:.transform(.uppercase))])
            let id = try #require(store.runWorkflow(pure,input:"kept")); try await fixture.drain(id)
            #expect(try fixture.task(id).output == "KEPT")
        }
    }

    @Test func workflowAwaitingApprovalKeepsItsOriginalCommandAndContractAfterDisableAndEdit() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            var command = SavedCommand(name:"Synthetic approved snapshot",executable:"/usr/bin/printf",arguments:["%s","{{input}}"],workingDirectory:fixture.directory.path)
            store.configuration.savedCommands = [command]
            let definition = WorkflowDefinition(name:"Synthetic frozen workflow",steps:[.init(operation:.savedCommand(command.id))])
            let id = try #require(store.runWorkflow(definition,input:"original"))
            try await fixture.eventually { !store.pendingApprovals.isEmpty }
            let approval = try #require(store.pendingApprovals.first)
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            command.arguments = ["%s","changed"]; store.configuration.savedCommands = [command]
            store.resolveApproval(approval.id,approved:true); try await fixture.drain(id)
            #expect(try fixture.task(id).output == "original")
            #expect((await fixture.childReceipts(id)).count == 1)
        }
    }

    @Test func agentAwaitingApprovalUsesItsFrozenAllowlistedCommandAfterDisableAndEdit() async throws {
        try await withStoreHTTPFixture(path:"agent-command") { fixture in
            let store = fixture.store
            var command = SavedCommand(name:"Synthetic Agent command",executable:"/usr/bin/printf",arguments:["%s","original"],workingDirectory:fixture.directory.path)
            store.configuration.savedCommands = [command]
            var definition = AgentDefinition(); definition.allowedCommandIDs = [command.id]
            let id = try #require(store.runAgent(definition,input:"Synthetic tool request"))
            try await storeEventually { store.pendingApprovals.contains(where:{$0.runID == id}) }
            let approval = try #require(store.pendingApprovals.first(where:{$0.runID == id}))
            #expect(approval.displayTitle == "Synthetic Agent command")
            #expect(approval.summary.contains("original") && approval.effects == [.executeProcess])
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            command.name = "Synthetic renamed command"; command.arguments = ["%s","changed"]; store.configuration.savedCommands = [command]
            #expect(store.runAgent(definition,input:"Synthetic blocked request") == nil)
            store.resolveApproval(approval.id,approved:true); try await fixture.drain(id)
            let task = try #require(store.tasks.first(where:{$0.id == id}))
            #expect(task.status == .completed && task.output.contains("original") && !task.output.contains("changed"))
            #expect(approval.displayTitle == "Synthetic Agent command" && approval.toolName.hasPrefix("command_"))
            #expect(task.output.contains("Synthetic saved command round-trip complete"))
            let toolReceipts = await store.agentToolStore.list()
            #expect(toolReceipts.count == 1 && store.tasks.count == 1)
            let stats = try await fixture.server.stats(); #expect(stats["agent_requests"] == 2 && stats["agent_tool_messages"] == 1)
        }
    }

    @Test func scheduledAuthorizationBindsInstalledContractButIgnoresEnablementEpoch() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name:"Synthetic scheduled CLI",executable:"/usr/bin/printf",arguments:["%s","synthetic"],workingDirectory:fixture.directory.path)
            store.configuration.savedCommands = [command]
            let workflow = WorkflowDefinition(name:"Synthetic schedule",steps:[.init(operation:.savedCommand(command.id))])
            store.configuration.workflows = [workflow]
            let before = try store.scheduleFingerprint(workflow.id)
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            #expect(try store.scheduleFingerprint(workflow.id) == before)
            let installed = try store.installedCommandContribution(), manifest = try SavedCommandContribution.manifest()
            let oldAction = manifest.descriptor.defaultAction
            let newAction = try ActionDescriptor(id:oldAction.id,version:oldAction.version+1,title:oldAction.title,inputType:oldAction.inputType,outputType:oldAction.outputType,requiredContext:oldAction.requiredContext,effects:oldAction.effects,execution:.init(toolID:oldAction.execution.toolID,toolVersion:oldAction.execution.toolVersion+1))
            let updated = try ContributionManifest(reference:manifest.reference,provider:manifest.provider,descriptor:.init(id:manifest.reference.toolID,version:manifest.reference.toolVersion,title:manifest.descriptor.title,providerID:manifest.provider.toolID,actions:[newAction]))
            let newContract = try FrozenCommandContribution(manifest:updated)
            #expect(try installed.fingerprint(command) != newContract.fingerprint(command))
            let tool = try SavedCommandAITool.make(command:command,resourceFingerprint:newContract.fingerprint(command),runner:store.processRunner,version:newContract.execution.toolVersion,executionToolID:newContract.execution.toolID,actionID:newContract.action.toolID,actionVersion:newContract.action.toolVersion)
            #expect(tool.version == 2 && tool.actionVersion == 2 && tool.executionToolID == newAction.execution.toolID)
        }
    }
}
