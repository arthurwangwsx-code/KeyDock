import Foundation
import Testing
import AutomationCore
import CommandCore
import ExecutionCore
@testable import WorkbenchFeature

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct WorkflowLaunchTests {
    private func workflow(_ name: String) -> WorkflowDefinition { .init(name: name, steps: [.init(operation: .transform(.trim))]) }
    private func install(_ values: [WorkflowDefinition], in store: WorkbenchModel) {
        store.configuration.workflows = values; store.rebuildCatalog()
    }
    private func item(_ definition: WorkflowDefinition, in store: WorkbenchModel) throws -> CommandItem {
        try #require(store.catalog.first { $0.id == "workflow." + definition.id.uuidString })
    }

    @Test(arguments: [ExecutionCaller.user, .shortcut]) func launcherRoutesTheExactWorkflowWithoutReplacingTheEditor(caller: ExecutionCaller) async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, a = workflow("Synthetic A"), b = workflow("Synthetic B")
            install([a, b], in: store)
            let session = WorkspaceSession(); session.workflowDraft = workflow("Unsaved editor A"); session.workflowInput = "Keep editor input"; session.page = .workflows
            let original = session.workflowDraft
            store.onOpenWorkspace = { [weak store] route in if let store { session.navigate(route, store: store) } }
            if caller == .shortcut { store.performWorkflowShortcut(id: "workflow." + b.id.uuidString) }
            else { store.execute(try item(b, in: store), caller: caller) }
            let launch = try #require(session.workflowLaunch)
            #expect(launch.definition == b && launch.input.isEmpty)
            #expect(session.workflowDraft == original && session.workflowInput == "Keep editor input" && session.page == .workflows)
            #expect(store.drafts.isEmpty && !session.canRunWorkflowLaunch(launch.id, in: store))
            session.cancelWorkflowLaunch(launch.id)
            #expect(session.workflowLaunch == nil && session.workflowDraft == original)
            await fixture.assertNoExecution()
        }
    }

    @Test func pendingInputsAndLateButtonsCannotBeReboundToAnotherPresentation() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, a = workflow("Synthetic A"), b = workflow("Synthetic B")
            install([a, b], in: store); let session = WorkspaceSession()
            #expect(session.prepareWorkflowLaunch(a.id, in: store))
            let first = try #require(session.workflowLaunch); first.editInput("Keep this input")
            #expect(session.prepareWorkflowLaunch(a.id, in: store))
            #expect(!session.prepareWorkflowLaunch(b.id, in: store))
            #expect(session.workflowLaunch === first && first.input == "Keep this input" && !first.notice.isEmpty)
            session.cancelWorkflowLaunch(first.id)
            #expect(session.prepareWorkflowLaunch(b.id, in: store))
            let second = try #require(session.workflowLaunch); second.editInput("New input")
            #expect(!session.runWorkflowLaunch(first.id, in: store))
            #expect(!session.reloadWorkflowLaunch(first.id, in: store))
            session.cancelWorkflowLaunch(first.id)
            #expect(session.workflowLaunch === second && second.input == "New input")
            await fixture.assertNoExecution()
        }
    }

    @Test func contextFreeShortcutRejectsStaleOrUnrelatedTargetsWithVisibleWorkspaceFeedback() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store; var opened = 0
            store.onOpenWorkspace = { if case .workflows = $0 { opened += 1 } }
            for id in ["workflow." + UUID().uuidString, "utility.ai"] {
                store.performWorkflowShortcut(id: id)
                #expect(!store.workspaceNotice.isEmpty)
            }
            #expect(opened == 2 && store.drafts.isEmpty)
            await fixture.assertNoExecution()
        }
    }

    @Test func changedDefinitionNeedsAnExplicitReloadAndKeepsExactInput() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, original = workflow("Synthetic exact input")
            install([original], in: store); let session = WorkspaceSession()
            #expect(session.prepareWorkflowLaunch(original.id, in: store))
            let launch = try #require(session.workflowLaunch), text = "  Synthetic e\u{301} text  "
            launch.editInput(text)
            var changed = original; changed.version += 1; changed.name = "Synthetic revised input"
            install([changed], in: store)
            #expect(!session.runWorkflowLaunch(launch.id, in: store))
            #expect(launch.needsReview && !launch.notice.isEmpty && launch.input.utf8.elementsEqual(text.utf8))
            await fixture.assertNoExecution()
            #expect(session.reloadWorkflowLaunch(launch.id, in: store))
            #expect(launch.definition == changed && launch.input.utf8.elementsEqual(text.utf8))
            #expect(session.runWorkflowLaunch(launch.id, in: store))
            let id = try #require(store.tasks.first?.id); try await fixture.drain(id)
            let result = try fixture.task(id)
            #expect(result.status == .completed && result.output.utf8.elementsEqual("Synthetic e\u{301} text".utf8))
            #expect(session.workflowLaunch == nil && store.tasks.count == 1)
            #expect(!session.runWorkflowLaunch(launch.id, in: store))
        }
    }

    @Test func deletedAndInvalidWorkflowReferencesNeverOpenOrExecuteAnotherDraft() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, original = workflow("Synthetic removed input")
            install([original], in: store); let oldItem = try item(original, in: store), session = WorkspaceSession()
            #expect(session.prepareWorkflowLaunch(original.id, in: store))
            let launch = try #require(session.workflowLaunch); launch.editInput("Retained")
            install([], in: store)
            #expect(!session.runWorkflowLaunch(launch.id, in: store) && launch.input == "Retained")
            #expect(!session.reloadWorkflowLaunch(launch.id, in: store))
            session.cancelWorkflowLaunch(launch.id)
            var routes = 0; store.onOpenWorkspace = { _ in routes += 1 }
            store.execute(oldItem)
            #expect(routes == 0 && !store.launcherNotice.isEmpty && !session.prepareWorkflowLaunch(original.id, in: store))
            let invalid = WorkflowDefinition(name: "Synthetic invalid reference", steps: [.init(operation: .savedCommand(UUID()))])
            install([invalid], in: store)
            store.execute(try item(invalid, in: store))
            #expect(routes == 0 && !session.prepareWorkflowLaunch(invalid.id, in: store))
            await fixture.assertNoExecution()
        }
    }

    @Test func oversizeUTF8IsRejectedWithoutKeepingOrRunningATruncatedInput() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, definition = workflow("Synthetic input limit")
            install([definition], in: store); let session = WorkspaceSession()
            #expect(session.prepareWorkflowLaunch(definition.id, in: store))
            let launch = try #require(session.workflowLaunch); launch.editInput("Synthetic kept")
            launch.editInput(String(repeating: "界", count: 43_691))
            #expect(launch.input == "Synthetic kept" && launch.inputRejected && !session.canRunWorkflowLaunch(launch.id, in: store))
            #expect(!session.runWorkflowLaunch(launch.id, in: store))
            #expect(session.reloadWorkflowLaunch(launch.id, in: store))
            #expect(launch.inputRejected && !launch.notice.isEmpty)
            launch.editInput("Synthetic legal edit")
            #expect(session.canRunWorkflowLaunch(launch.id, in: store) && !launch.inputRejected)
            store.shutdown()
            #expect(!session.runWorkflowLaunch(launch.id, in: store))
            await fixture.assertNoExecution()
        }
    }

    @Test func fixedCommandPipelineStillRunsDirectlyAndManualInputIsAskedOnlyByItsStep() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name: "Synthetic fixed printf", executable: "/usr/bin/printf", arguments: ["%s", "Synthetic fixed"], workingDirectory: fixture.directory.path)
            store.configuration.savedCommands = [command]
            let fixed = WorkflowDefinition(name: "Synthetic fixed launch", steps: [.init(operation: .savedCommand(command.id)), .init(operation: .transform(.uppercase), input: .previousOutput)])
            install([fixed], in: store)
            var openedID: UUID?; store.onOpenWorkspace = { if case .tasks(let id) = $0 { openedID = id } }
            store.execute(try item(fixed, in: store))
            let id = try #require(openedID); try await fixture.drain(id)
            #expect(try fixture.task(id).output == "SYNTHETIC FIXED")
            let manual = WorkflowDefinition(name: "Synthetic manual launch", steps: [.init(operation: .manualInput), .init(operation: .transform(.uppercase), input: .previousOutput)])
            install([manual], in: store); openedID = nil
            store.execute(try item(manual, in: store))
            let manualID = try #require(openedID)
            try await fixture.eventually { store.pendingWorkflowInputs.contains { $0.runID == manualID } }
            let request = try #require(store.pendingWorkflowInputs.first { $0.runID == manualID })
            #expect(request.initialValue.isEmpty)
            store.resolveWorkflowInput(request.id, value: "Synthetic single answer")
            try await fixture.drain(manualID)
            #expect(try fixture.task(manualID).output == "SYNTHETIC SINGLE ANSWER")
        }
    }

    @Test func aiAndDynamicCommandInputsAreCollectedBeforeAnyRequestOrProcess() async throws {
        try await withStoreHTTPFixture(path: "normal") { fixture in
            let store = fixture.store, ai = WorkflowDefinition(name: "Synthetic AI input launch", steps: [.init(operation: .aiAction(fixture.action.id))])
            install([ai], in: store); let session = WorkspaceSession()
            store.onOpenWorkspace = { [weak store] route in if let store { session.navigate(route, store: store) } }
            store.execute(try item(ai, in: store), caller: .shortcut)
            #expect(session.workflowLaunch?.definition.id == ai.id && store.tasks.isEmpty && store.drafts.isEmpty)
            #expect(try await fixture.server.stats()["post_requests"] == 0)
        }
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name: "Synthetic dynamic printf", executable: "/usr/bin/printf", arguments: ["%s", "{{input}}"], workingDirectory: fixture.directory.path)
            store.configuration.savedCommands = [command]
            let definition = WorkflowDefinition(name: "Synthetic command input launch", steps: [.init(operation: .savedCommand(command.id))])
            install([definition], in: store); var requestedID: UUID?
            store.onOpenWorkspace = { if case .workflowInput(let id) = $0 { requestedID = id } }
            store.execute(try item(definition, in: store))
            #expect(requestedID == definition.id)
            await fixture.assertNoExecution()
        }
    }
}
