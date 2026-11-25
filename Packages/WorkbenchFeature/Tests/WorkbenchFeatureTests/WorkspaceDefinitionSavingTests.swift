import Foundation
import Testing
import AgentCore
import AutomationCore
import MacAdapters
@testable import WorkbenchFeature

/// 发起保存的窗口会话、真实文件补偿和版本；不运行模型、工具或系统动作。
@Suite(.serialized) @MainActor struct WorkspaceDefinitionSavingTests {
    private func withStore(_ body: (WorkbenchModel, InterfaceWriteRelay, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-DefinitionSaving-" + UUID().uuidString)
        let relay = InterfaceWriteRelay()
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in }, configurationWriter: relay.write,
            applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        try body(store, relay, directory.appendingPathComponent("configuration.json"))
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after], [false, true])
    func agentFailurePreservesDraftVersionInputAndExactFile(failure: InterfaceWriteRelay.Failure, editing: Bool) throws {
        try withStore { store, relay, file in
            let session = WorkspaceSession()
            session.agentProfile.name = "Synthetic profile"
            if editing { #expect(session.saveAgentProfile(in: store)) }
            let original = try? Data(contentsOf: file)
            let saved = store.configuration.agents
            session.agentProfile.instructions = "Synthetic unsaved instructions\nkeep é"
            session.agentInput = "Synthetic task input"
            let draft = session.agentProfile
            relay.failure = failure
            #expect(!session.saveAgentProfile(in: store))
            #expect(session.agentProfile == draft && session.agentInput == "Synthetic task input")
            #expect(store.configuration.agents == saved)
            #expect(store.workspaceNoticeMessage == store.settingsNoticeMessage && !store.workspaceNotice.isEmpty)
            #expect((try? Data(contentsOf: file)) == original)
            #expect(session.agentProfileSaveState(in: store) == (editing ? .modified : .notSaved))
            #expect(session.saveAgentProfile(in: store))
            #expect(store.workspaceNotice.isEmpty)
            #expect(session.agentProfileSaveState(in: store) == .saved(editing ? 2 : 1))
            let persisted = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: file))
            #expect(persisted.agents.first(where: { $0.id == draft.id }) == session.agentProfile)
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after], [false, true])
    func workflowFailurePreservesStepsVersionInputAndExactFile(failure: InterfaceWriteRelay.Failure, editing: Bool) throws {
        try withStore { store, relay, file in
            let session = WorkspaceSession()
            session.workflowDraft.name = "Synthetic workflow"
            if editing { #expect(session.saveWorkflow(in: store)) }
            let original = try? Data(contentsOf: file)
            let saved = store.configuration.workflows
            session.workflowDraft.steps.append(.init(operation: .transform(.uppercase), input: .previousOutput))
            session.workflowInput = "Synthetic initial input"
            let draft = session.workflowDraft
            relay.failure = failure
            #expect(!session.saveWorkflow(in: store))
            #expect(session.workflowDraft == draft && session.workflowInput == "Synthetic initial input")
            #expect(store.configuration.workflows == saved)
            #expect(store.workspaceNoticeMessage == store.settingsNoticeMessage && !store.workspaceNotice.isEmpty)
            #expect((try? Data(contentsOf: file)) == original)
            #expect(session.workflowSaveState(in: store) == (editing ? .modified : .notSaved))
            #expect(session.saveWorkflow(in: store))
            #expect(store.workspaceNotice.isEmpty)
            #expect(session.workflowSaveState(in: store) == .saved(editing ? 2 : 1))
            let persisted = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: file))
            #expect(persisted.workflows.first(where: { $0.id == draft.id }) == session.workflowDraft)
        }
    }

    @Test func saveStatusTracksRealEditsNavigationAndSelectedDefinition() throws {
        try withStore { store, _, _ in
            let session = WorkspaceSession()
            #expect(session.agentProfileSaveState(in: store) == .notSaved)
            #expect(session.workflowSaveState(in: store) == .notSaved)
            session.agentProfile.name = "Synthetic Café"
            session.workflowDraft.name = "Synthetic Café"
            session.workflowDraft.steps[0].input = .literal("Café")
            #expect(session.saveAgentProfile(in: store) && session.saveWorkflow(in: store))
            #expect(session.agentProfileSaveState(in: store) == .saved(1))
            #expect(session.workflowSaveState(in: store) == .saved(1))
            session.agentProfile.name = "Synthetic Cafe\u{301}"
            session.workflowDraft.steps[0].input = .literal("Cafe\u{301}")
            #expect(session.agentProfileSaveState(in: store) == .modified)
            #expect(session.workflowSaveState(in: store) == .modified)
            session.navigate(.tasks(nil), store: store); session.navigate(.agent, store: store)
            #expect(session.agentProfileSaveState(in: store) == .modified)
            #expect(session.saveAgentProfile(in: store) && session.saveWorkflow(in: store))
            #expect(session.agentProfileSaveState(in: store) == .saved(2))
            #expect(session.workflowSaveState(in: store) == .saved(2))
            session.agentProfile = AgentDefinition()
            session.workflowDraft = WorkflowDefinition(name: "", steps: [])
            #expect(session.agentProfileSaveState(in: store) == .notSaved)
            #expect(session.workflowSaveState(in: store) == .notSaved)
        }
    }

    @Test func invalidAndShutdownSavesShowFailureAndKeepDrafts() throws {
        try withStore { store, _, file in
            let session = WorkspaceSession()
            session.agentProfile.name = " "; session.agentProfile.instructions = "Synthetic keep instructions"
            let agent = session.agentProfile, workflow = session.workflowDraft
            #expect(!session.saveAgentProfile(in: store) && !store.workspaceNotice.isEmpty)
            #expect(!session.saveWorkflow(in: store) && !store.workspaceNotice.isEmpty)
            #expect(session.agentProfile == agent && session.workflowDraft == workflow)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            store.shutdown()
            #expect(!session.saveAgentProfile(in: store))
            #expect(store.workspaceNoticeMessage == noticeKey("KeyDock is quitting. No new action was started."))
            #expect(!session.saveWorkflow(in: store))
            #expect(store.workspaceNoticeMessage == noticeKey("KeyDock is quitting. No new action was started."))
            #expect(session.agentProfile == agent && session.workflowDraft == workflow)
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func failedAgentAndLegacyWorkflowRemovalPreserveBothDefinitions(failure: InterfaceWriteRelay.Failure) throws {
        try withStore { store, relay, file in
            let session = WorkspaceSession(); session.workflowDraft.name = "Synthetic workflow"
            #expect(session.saveAgentProfile(in: store) && session.saveWorkflow(in: store))
            let bytes = try Data(contentsOf: file)
            relay.failure = failure
            #expect(!store.removeAgent(session.agentProfile.id))
            #expect(store.workspaceNoticeMessage == store.settingsNoticeMessage && !store.workspaceNotice.isEmpty)
            relay.failure = failure
            #expect(!store.removeWorkflow(session.workflowDraft.id))
            #expect(store.workspaceNoticeMessage == noticeKey("Review this workflow in Workflows before removing it."))
            #expect(session.agentProfileSaveState(in: store) == .saved(1))
            #expect(session.workflowSaveState(in: store) == .saved(1))
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
