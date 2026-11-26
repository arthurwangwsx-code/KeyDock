import Foundation
import Testing
import AutomationCore
import ExecutionCore
@testable import WorkbenchFeature

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct WorkflowIntegrationTests {
    @Test func printfThenTextTransformsProduceOneTaskAndDurableReceipts() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name: "Synthetic printf", executable: "/usr/bin/printf", arguments: ["%s", "  hello 世界\n"], workingDirectory: fixture.directory.path)
            store.configuration.savedCommands = [command]
            let definition = WorkflowDefinition(name: "Synthetic text pipeline", steps: [
                .init(operation: .savedCommand(command.id)),
                .init(operation: .transform(.trim), input: .previousOutput),
                .init(operation: .transform(.uppercase), input: .previousOutput)
            ])
            let runID = try #require(store.runWorkflow(definition, input: "Unused synthetic input"))
            try await fixture.drain(runID)
            let task = try fixture.task(runID)
            #expect(task.status == .completed && task.output == "HELLO 世界" && task.finishedAt != nil)
            #expect(store.tasks.count == 1 && store.pendingApprovals.isEmpty && store.pendingWorkflowInputs.isEmpty)
            let checkpoint = try #require(store.workflowCheckpoints[runID])
            #expect(checkpoint.stepIndex == 2 && checkpoint.phase == .succeeded && checkpoint.sequence == 5)
            let parents = await store.aiInvocationStore.list(), children = await fixture.childReceipts(runID)
            #expect(parents.count == 1 && parents.first?.id == runID && parents.first?.state == .succeeded)
            #expect(children.count == 1 && children.first?.state == .succeeded)
            let cli = await store.invocationStore.list()
            #expect(cli.isEmpty)
        }
    }

    @Test func boundArgumentRequiresCompleteApprovalAndShellSyntaxStaysLiteral() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, marker = fixture.directory.appendingPathComponent("must-never-be-created")
            let input = "$(/usr/bin/touch '" + marker.path + "') ; $HOME * 'single' \"double\"\n中文🙂"
            let command = SavedCommand(name: "Synthetic bound printf", executable: "/usr/bin/printf", arguments: ["%s", "{{input}}"], workingDirectory: fixture.directory.path)
            store.configuration.savedCommands = [command]
            let definition = WorkflowDefinition(name: "Synthetic bound input", steps: [.init(operation: .savedCommand(command.id))])
            let runID = try #require(store.runWorkflow(definition, input: input))
            try await fixture.eventually { store.pendingApprovals.contains { $0.runID == runID } }
            let proposal = try #require(store.pendingApprovals.first { $0.runID == runID })
            let expected = command.executable + " " + ["%s", input].map { String(reflecting: $0) }.joined(separator: " ") + "\n" + command.workingDirectory
            #expect(proposal.summary == expected && proposal.effects == [.executeProcess])
            #expect(proposal.toolName == "workflow_command" && proposal.runID == runID)
            #expect(proposal.displayTitle == command.name)
            let waiting = try fixture.task(runID), beforeChildren = await fixture.childReceipts(runID)
            #expect(waiting.status == .awaitingApproval && waiting.output.isEmpty && beforeChildren.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            store.resolveApproval(proposal.id, approved: true)
            try await fixture.drain(runID)
            let completed = try fixture.task(runID), children = await fixture.childReceipts(runID)
            #expect(completed.status == .completed && completed.output == input)
            #expect(children.count == 1 && children.first?.state == .succeeded)
            #expect(store.pendingApprovals.isEmpty && !FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func deniedDynamicArgumentNeverDispatchesItsCommand() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, marker = fixture.directory.appendingPathComponent("denied-command-marker")
            let command = SavedCommand(name: "Synthetic denied touch", executable: "/usr/bin/touch", arguments: ["{{input}}"], workingDirectory: fixture.directory.path)
            store.configuration.savedCommands = [command]
            let definition = WorkflowDefinition(name: "Synthetic denied workflow", steps: [.init(operation: .savedCommand(command.id))])
            let runID = try #require(store.runWorkflow(definition, input: marker.path))
            try await fixture.eventually { store.pendingApprovals.contains { $0.runID == runID } }
            let proposal = try #require(store.pendingApprovals.first { $0.runID == runID })
            #expect(proposal.summary.contains(String(reflecting: marker.path)))
            store.resolveApproval(proposal.id, approved: false)
            try await fixture.drain(runID)
            let task = try fixture.task(runID), children = await fixture.childReceipts(runID)
            #expect(task.status == .cancelled && task.output.isEmpty && children.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            let parents = await store.aiInvocationStore.list()
            #expect(parents.first { $0.id == runID }?.state == .cancelled)
        }
    }

    @Test func editingSavedCommandAndDefinitionWhileAwaitingApprovalDoesNotChangeCurrentRun() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let original = SavedCommand(name: "Synthetic frozen printf", executable: "/usr/bin/printf", arguments: ["%s", "{{input}}"], workingDirectory: fixture.directory.path)
            let definition = WorkflowDefinition(name: "Synthetic frozen workflow", steps: [
                .init(operation: .savedCommand(original.id)), .init(operation: .transform(.uppercase), input: .previousOutput)
            ])
            store.configuration.savedCommands = [original]; store.configuration.workflows = [definition]
            let firstID = try #require(store.runWorkflow(definition, input: "Original Mixed"))
            try await fixture.eventually { store.pendingApprovals.contains { $0.runID == firstID } }
            let pending = try #require(store.pendingApprovals.first { $0.runID == firstID })
            var replacement = original
            replacement.name = "Synthetic updated printf"; replacement.arguments = ["%s", "UPDATED"]
            var edited = definition
            edited.version += 1; edited.steps[1].operation = .transform(.lowercase)
            var next = store.configuration; next.savedCommands = [replacement]; next.workflows = [edited]
            #expect(store.commitSettingsConfiguration(next))
            #expect(pending.summary.contains(String(reflecting: "Original Mixed")))
            store.resolveApproval(pending.id, approved: true)
            try await fixture.drain(firstID)
            let originalTask = try fixture.task(firstID)
            #expect(originalTask.status == .completed && originalTask.output == "ORIGINAL MIXED")
            #expect(store.workflowCheckpoints[firstID]?.definitionVersion == definition.version)
            let secondID = try #require(store.runWorkflow(edited, input: "New input"))
            try await fixture.drain(secondID)
            let updatedTask = try fixture.task(secondID)
            #expect(updatedTask.status == .completed && updatedTask.output == "updated")
            #expect(store.workflowCheckpoints[secondID]?.definitionVersion == edited.version)
            #expect(store.pendingApprovals.isEmpty)
        }
    }

    @Test func unattendedWorkflowRejectsDynamicArgumentsBeforeCreatingAnyTaskOrIntent() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, marker = fixture.directory.appendingPathComponent("unattended-must-not-run")
            let command = SavedCommand(name: "Synthetic unattended rejection", executable: "/usr/bin/touch", arguments: ["{{input}}"], workingDirectory: fixture.directory.path)
            store.configuration.savedCommands = [command]
            let definition = WorkflowDefinition(name: "Synthetic unattended workflow", steps: [.init(operation: .savedCommand(command.id))])
            #expect(throws: WorkflowCompileError.self) { _ = try store.compileWorkflow(definition, interaction: false) }
            #expect(store.runWorkflow(definition, input: marker.path, interaction: false) == nil)
            await fixture.assertNoExecution(markers: [marker])
        }
    }

    @Test func nulInBoundArgumentFailsBeforeApprovalOrChildIntent() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name: "Synthetic invalid bound input", executable: "/usr/bin/printf", arguments: ["%s", "{{input}}"], workingDirectory: fixture.directory.path)
            store.configuration.savedCommands = [command]
            let definition = WorkflowDefinition(name: "Synthetic invalid binding", steps: [.init(operation: .savedCommand(command.id))])
            let runID = try #require(store.runWorkflow(definition, input: "synthetic\0suffix"))
            try await fixture.drain(runID)
            let task = try fixture.task(runID), children = await fixture.childReceipts(runID)
            #expect(task.status == .failed && task.output.isEmpty && children.isEmpty && store.pendingApprovals.isEmpty)
        }
    }
}
