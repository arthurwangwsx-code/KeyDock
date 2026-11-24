import Foundation
import Testing
import ExecutionCore
import CommandCore
import AgentCore
import AutomationCore
import MacAdapters
@testable import WorkbenchFeature

@MainActor private final class SavedItemLifecycleFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-SavedItem-" + UUID().uuidString)
    let relay = InterfaceWriteRelay()
    let store: WorkbenchModel
    var runtime: [ShortcutPlanEntry] = []
    var failRegistration = false
    var failRestoration = false
    var registrationCalls = 0
    init() throws {
        store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in }, configurationWriter: relay.write,
            applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
        runtime = ShortcutPlan.entries(store.configuration)
        store.onShortcutConfigurationChanged = { [weak self] next in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            registrationCalls += 1
            if failRegistration || (failRestoration && registrationCalls == 2) { throw HotkeyRegistrationError(status: -50) }
            runtime = ShortcutPlan.entries(next)
        }
    }
    var file: URL { directory.appendingPathComponent("configuration.json") }
    func add(ai: Bool, shortcut: Bool = false) throws -> SavedItemTarget {
        if ai {
            var value = AIActionPreset(name: "Synthetic action", prompt: "Synthetic prompt")
            if shortcut { value.shortcut = HotkeyBinding(keyCode: 2) }
            #expect(store.saveAction(value)); return .aiAction(value.id)
        }
        let value = SavedCommand(name: "Synthetic command", executable: "/usr/bin/printf", workingDirectory: directory.path)
        #expect(store.saveCommand(value))
        if shortcut { #expect(store.setShortcut(HotkeyBinding(keyCode: 2), for: "command." + value.id.uuidString)) }
        return .command(value.id)
    }
    func cleanup() async { await store.shutdownAndWait(); try? FileManager.default.removeItem(at: directory) }
}

/// 真实配置事务与loopback／owned进程，注册端口为合成计划；不注册OS按键或操作个人数据。
@Suite(.serialized) @MainActor struct SavedItemLifecycleTests {
    private func withFixture(_ body: (SavedItemLifecycleFixture) async throws -> Void) async throws {
        let fixture = try SavedItemLifecycleFixture()
        do { try await body(fixture); await fixture.cleanup() }
        catch { await fixture.cleanup(); throw error }
    }

    @Test(arguments: [false, true]) func removalCleansOnlyExactMetadataAndSurvivesReload(ai: Bool) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(ai: ai, shortcut: true)
            let neighbor = target.commandID + ".different"
            var next = store.configuration
            for id in [target.commandID, neighbor] { next.preferences.favorites.insert(id); next.preferences.aliases[id] = "Synthetic alias"; next.preferences.recent[id] = Date(timeIntervalSince1970: 1) }
            next.commandShortcuts[neighbor] = HotkeyBinding(keyCode: 3)
            if ai { next.commandShortcuts[target.commandID] = HotkeyBinding(keyCode: 2) }
            #expect(store.commitShortcutConfiguration(next))
            let review = try #require(store.reviewSavedItemRemoval(target))
            #expect(review.dependencies.isEmpty && store.removeSavedItem(review))
            #expect(!store.catalog.contains { $0.id == target.commandID })
            #expect(!fixture.runtime.contains { $0.commandID == target.commandID })
            #expect(store.configuration.commandShortcuts[target.commandID] == nil)
            #expect(store.configuration.commandShortcuts[neighbor] == HotkeyBinding(keyCode: 3))
            #expect(!store.configuration.preferences.favorites.contains(target.commandID))
            #expect(store.configuration.preferences.aliases[target.commandID] == nil && store.configuration.preferences.recent[target.commandID] == nil)
            #expect(store.configuration.preferences.favorites.contains(neighbor) && store.configuration.preferences.aliases[neighbor] != nil && store.configuration.preferences.recent[neighbor] != nil)
            let reloaded = try WorkbenchModel(dataDirectory: fixture.directory, allowContextCapture: false,
                clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
                applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
            #expect(reloaded.reviewSavedItemRemoval(target) == nil)
            await reloaded.shutdownAndWait()
        }
    }

    @Test(arguments: [false, true]) func allTypedReferencesAndIndirectSchedulesPreventRemoval(ai: Bool) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(ai: ai)
            let operation: WorkflowOperation
            switch target { case .command(let id): operation = .savedCommand(id); case .aiAction(let id): operation = .aiAction(id) }
            let workflow = WorkflowDefinition(name: "Synthetic reference", steps: [.init(operation: operation)])
            #expect(store.saveWorkflow(workflow))
            var next = store.configuration
            next.collections = [try CommandCollection(name: "Synthetic direct", commandIDs: [target.commandID]), try CommandCollection(name: "Synthetic indirect", commandIDs: ["workflow." + workflow.id.uuidString])]
            if case .command(let id) = target { var agent = AgentDefinition(); agent.allowedCommandIDs = [id]; next.agents.append(agent) }
            #expect(store.commitSettingsConfiguration(next))
            await store.addSchedule(name: "Synthetic disabled schedule", workflowID: workflow.id, trigger: .interval(seconds: 60))
            let bytes = try Data(contentsOf: fixture.file)
            let review = try #require(store.reviewSavedItemRemoval(target))
            #expect(review.dependencies.filter { $0.kind == .workflow }.count == 1)
            #expect(review.dependencies.filter { $0.kind == .collection }.count == 2)
            #expect(review.dependencies.filter { $0.kind == .schedule }.count == 1)
            #expect(review.dependencies.filter { $0.kind == .agent }.count == (ai ? 0 : 1))
            #expect(!store.removeSavedItem(review) && !store.settingsNotice.isEmpty)
            #expect(try Data(contentsOf: fixture.file) == bytes)
        }
    }

    @Test(arguments: [false, true]) func confirmationRechecksDefinitionAndNewReferences(ai: Bool) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(ai: ai)
            let old = try #require(store.reviewSavedItemRemoval(target))
            switch target {
            case .command(let id): var value = try #require(store.configuration.savedCommands.first { $0.id == id }); value.name += " edited"; #expect(store.saveCommand(value))
            case .aiAction(let id): var value = try #require(store.configuration.aiActions.first { $0.id == id }); value.prompt += " edited"; #expect(store.saveAction(value))
            }
            #expect(!store.removeSavedItem(old))
            let current = try #require(store.reviewSavedItemRemoval(target))
            var next = store.configuration
            next.collections.append(try CommandCollection(name: "Synthetic late reference", commandIDs: [target.commandID]))
            #expect(store.commitSettingsConfiguration(next))
            let bytes = try Data(contentsOf: fixture.file)
            #expect(!store.removeSavedItem(current))
            #expect(try Data(contentsOf: fixture.file) == bytes)
        }
    }

    @Test(arguments: [false, true], [InterfaceWriteRelay.Failure.before, .after])
    func writerFailureRestoresFilePlanPreferencesAndReview(ai: Bool, failure: InterfaceWriteRelay.Failure) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(ai: ai, shortcut: true)
            var next = store.configuration; next.preferences.favorites.insert(target.commandID); next.preferences.aliases[target.commandID] = "Synthetic alias"
            #expect(store.commitSettingsConfiguration(next))
            let bytes = try Data(contentsOf: fixture.file), runtime = fixture.runtime
            let session = SettingsSession(store: store); session.prepareRemoval(target, in: store)
            let id = try #require(session.savedItemRemoval?.id)
            let reviewID = try #require(session.savedItemRemoval?.review.id)
            fixture.relay.failure = failure
            #expect(!session.confirmRemoval(reviewID, in: store))
            #expect(session.savedItemRemoval?.id == id && !store.settingsNotice.isEmpty)
            #expect(fixture.runtime == runtime && !store.shortcutsUnavailable)
            #expect(store.configuration.preferences.favorites.contains(target.commandID) && store.configuration.preferences.aliases[target.commandID] != nil)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(session.confirmRemoval(reviewID, in: store) && session.savedItemRemoval == nil)
        }
    }

    @Test func registrationFailureAndIncompleteRollbackRemainExplicit() async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(ai: false, shortcut: true)
            let review = try #require(store.reviewSavedItemRemoval(target))
            let bytes = try Data(contentsOf: fixture.file), runtime = fixture.runtime
            fixture.failRegistration = true
            #expect(!store.removeSavedItem(review) && fixture.runtime == runtime)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            fixture.failRegistration = false; fixture.registrationCalls = 0; fixture.failRestoration = true; fixture.relay.failure = .after
            #expect(!store.removeSavedItem(review) && store.shortcutsUnavailable)
            #expect(store.settingsNoticeMessage == noticeKey("Shortcut changes could not be saved and rollback was incomplete. Check the saved shortcuts before retrying."))
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(store.catalog.contains { $0.id == target.commandID })
        }
    }

    @Test func lateConfirmationAndCancellationCannotAffectANewPresentation() async throws {
        try await withFixture { fixture in
            let store = fixture.store, session = SettingsSession(store: fixture.store)
            let first = try fixture.add(ai: false), second = try fixture.add(ai: true)
            session.prepareRemoval(first, in: store); let oldID = try #require(session.savedItemRemoval?.id)
            let oldReviewID = try #require(session.savedItemRemoval?.review.id)
            session.cancelRemoval(oldID)
            session.prepareRemoval(second, in: store); let newID = try #require(session.savedItemRemoval?.id)
            let reviewID = try #require(session.savedItemRemoval?.review.id)
            session.beginNewCommand(); session.beginNewAction()
            #expect(session.editedCommand == nil && session.editedAction == nil)
            #expect(!session.confirmRemoval(oldReviewID, in: store)); session.cancelRemoval(oldID)
            #expect(session.savedItemRemoval?.id == newID)
            session.refreshRemoval(newID, in: store)
            #expect(session.savedItemRemoval?.id == newID && session.savedItemRemoval?.review.id != reviewID)
            #expect(!session.confirmRemoval(reviewID, in: store))
            #expect(store.reviewSavedItemRemoval(first) != nil && store.reviewSavedItemRemoval(second) != nil)
            session.cancelRemoval(newID)
            #expect(session.savedItemRemoval == nil)
        }
    }

    @Test(arguments: [false, true]) func removedEditCannotResurrectAndNewCreationIsExplicit(ai: Bool) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(ai: ai), session = SettingsSession(store: fixture.store)
            switch target {
            case .command(let id): session.editCommand(try #require(store.configuration.savedCommands.first { $0.id == id }))
            case .aiAction(let id): session.editAction(try #require(store.configuration.aiActions.first { $0.id == id }))
            }
            #expect(store.removeSavedItem(try #require(store.reviewSavedItemRemoval(target))))
            let bytes = try Data(contentsOf: fixture.file)
            if let draft = session.editedCommand { #expect(!session.saveEditedCommand(draft, in: store)); #expect(session.editedCommand == draft) }
            if let draft = session.editedAction { #expect(!session.saveEditedAction(draft, in: store)); #expect(session.editedAction?.id == draft.id) }
            #expect(!store.settingsNotice.isEmpty)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            session.editedCommand = nil; session.editedAction = nil
            if ai {
                session.beginNewAction(); var draft = try #require(session.editedAction); draft.name = "Synthetic new"; draft.prompt = "Synthetic new prompt"
                #expect(session.saveEditedAction(draft, in: store)); #expect("ai." + draft.id.uuidString != target.commandID)
            } else {
                session.beginNewCommand(); var draft = try #require(session.editedCommand); draft.name = "Synthetic new"
                #expect(session.saveEditedCommand(draft, in: store)); #expect("command." + draft.id.uuidString != target.commandID)
            }
        }
    }

    @Test func anUnsavedAgentCannotReintroduceADeletedCommandReference() async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(ai: false)
            guard case .command(let id) = target else { return }
            let session = WorkspaceSession(); session.agentProfile.allowedCommandIDs = [id]; session.agentInput = "Synthetic task"
            #expect(store.removeSavedItem(try #require(store.reviewSavedItemRemoval(target))))
            let draft = session.agentProfile, bytes = try Data(contentsOf: fixture.file)
            #expect(!session.saveAgentProfile(in: store))
            #expect(session.agentProfile == draft && session.agentInput == "Synthetic task")
            #expect(try Data(contentsOf: fixture.file) == bytes)
            session.agentProfile.allowedCommandIDs.remove(id)
            #expect(session.saveAgentProfile(in: store))
        }
    }

    @Test func deletingAnActionPreservesInFlightAndFinishedResultAccess() async throws {
        var copies: [String] = []
        try await withStoreHTTPFixture(path: "stream", clipboardWriter: { copies.append($0) }) { fixture in
            let store = fixture.store, draft = store.createDraft(actionID: fixture.action.id, input: "Synthetic retained input")
            let run = try #require(store.runAIFromInput(draft))
            #expect(store.removeSavedItem(try #require(store.reviewSavedItemRemoval(.aiAction(fixture.action.id)))))
            #expect(draft.actionID == fixture.action.id && draft.latestRunID == run && draft.input == "Synthetic retained input")
            #expect(!store.canRunAIFromInput(draft) && store.runAIFromInput(draft) == nil)
            try await fixture.drain(run)
            #expect(store.tasks.first(where: { $0.id == run })?.status == .completed)
            #expect(store.tasks.first(where: { $0.id == run })?.output == "你好，网络 🌍")
            #expect(draft.latestRunID == run && !store.tasks.isEmpty)
            store.copyResult(run)
            #expect(copies == ["你好，网络 🌍"])
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func failedInitialBuiltinRemovalRestoresTheAbsentConfigurationFile(failure: InterfaceWriteRelay.Failure) async throws {
        try await withFixture { fixture in
            #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
            let id = try #require(fixture.store.configuration.aiActions.first?.id)
            let review = try #require(fixture.store.reviewSavedItemRemoval(.aiAction(id)))
            fixture.relay.failure = failure
            #expect(!fixture.store.removeSavedItem(review))
            #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
            #expect(fixture.store.configuration.aiActions.contains { $0.id == id })
        }
    }

    @Test func anUnsavedRunningWorkflowKeepsItsFrozenCommandAfterDeletion() async throws {
        let fixture = try WorkflowIntegrationFixture()
        do {
            await fixture.stopAutomaticWork()
            let command = SavedCommand(name: "Synthetic frozen command", executable: "/usr/bin/printf", arguments: ["%s", "{{input}}"], workingDirectory: fixture.directory.path)
            #expect(fixture.store.saveCommand(command))
            let workflow = WorkflowDefinition(name: "Synthetic unsaved run", steps: [.init(operation: .savedCommand(command.id))])
            let run = try #require(fixture.store.runWorkflow(workflow, input: "Synthetic frozen output"))
            try await fixture.eventually { fixture.store.pendingApprovals.first?.runID == run }
            #expect(fixture.store.removeSavedItem(try #require(fixture.store.reviewSavedItemRemoval(.command(command.id)))))
            fixture.store.resolveApproval(try #require(fixture.store.pendingApprovals.first?.id), approved: true)
            try await fixture.drain(run)
            #expect(try fixture.task(run).status == .completed && fixture.task(run).output == "Synthetic frozen output")
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }
}
