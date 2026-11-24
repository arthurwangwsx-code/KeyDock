import Foundation
import Testing
import CommandCore
import MacAdapters
import ExecutionCore
@testable import WorkbenchFeature

/// 合成配置与纯工作区动作；不打开应用、不运行CLI或请求AI。
@Suite(.serialized) @MainActor struct CollectionEditingTests {
    private let order = ["utility.tasks", "utility.agent", "utility.ai"]
    private func withStore(_ body: (WorkbenchModel, InterfaceWriteRelay, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-CollectionEditing-" + UUID().uuidString)
        let relay = InterfaceWriteRelay()
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in }, configurationWriter: relay.write,
            applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        try body(store, relay, directory.appendingPathComponent("configuration.json"))
    }
    private func add(_ name: String, to store: WorkbenchModel) throws -> CommandCollection {
        #expect(store.saveCollection(id: nil, name: name, commandIDs: order))
        return try #require(store.configuration.collections.last)
    }

    @Test func renameAndReopenKeepNonLexicalOrderAndNeverExecute() throws {
        try withStore { store, _, file in
            var executions = 0; store.onOpenWorkspace = { _ in executions += 1 }
            let original = try add("Synthetic A", to: store)
            let session = WorkspaceSession(); session.navigate(.collection(original.id), store: store)
            #expect(session.collectionDraft == CollectionEditorDraft())
            session.editCollection(original); session.collectionDraft.name = "Synthetic A renamed"
            #expect(session.saveCollection(in: store))
            let disk = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: file))
            #expect(disk.collections.first?.id == original.id)
            #expect(disk.collections.first?.commandIDs == order)
            session.editCollection(try #require(disk.collections.first))
            #expect(session.collectionDraft.commandIDs == order)
            #expect(executions == 0 && store.tasks.isEmpty)
        }
    }

    @Test func browsingDoesNotAssignEditIdentityAndEditingSurvivesNavigation() throws {
        try withStore { store, _, _ in
            let original = try add("Synthetic A", to: store)
            let session = WorkspaceSession(); session.selectedCollectionID = original.id
            session.collectionDraft.name = "Synthetic B"
            session.selectCollectionAction(order[2], selected: true, in: store)
            #expect(session.saveCollection(in: store))
            let other = try #require(store.configuration.collections.last)
            #expect(other.id != original.id && store.configuration.collections.first == original)
            session.editCollection(original)
            session.collectionDraft.name = "Synthetic A edited"
            session.collectionDraft.actionFilter = "Synthetic search"
            session.collectionDraft.choosingActions = true
            let moved = session.collectionDraft.move(order[2], by: -1)
            #expect(moved)
            let draft = session.collectionDraft
            session.navigate(.tasks(nil), store: store); session.navigate(.collection(other.id), store: store)
            #expect(session.collectionDraft == draft && session.selectedCollectionID == other.id)
            #expect(session.saveCollection(in: store))
            #expect(store.configuration.collections.first?.commandIDs == [order[0], order[2], order[1]])
            #expect(store.configuration.collections.last == other)
            #expect(session.collectionDraft == CollectionEditorDraft())
        }
    }

    @Test func draftAppendMoveRemovalAndCapacityKeepUserOrder() {
        var draft = CollectionEditorDraft()
        let ids = (0..<32).map { "utility.synthetic-\($0)" }
        for id in ids { let added = draft.select(id, selected: true); #expect(added) }
        let repeated = draft.select(ids[0], selected: true)
        let overflow = draft.select("utility.overflow", selected: true)
        let beforeFirst = draft.move(ids[0], by: -1), afterLast = draft.move(ids[31], by: 1)
        let invalidDistance = draft.move(ids[0], by: 2), missing = draft.move("utility.missing", by: 1)
        #expect(repeated && !overflow)
        #expect(!beforeFirst && !afterLast && !invalidDistance && !missing)
        #expect(draft.commandIDs == ids)
        let moved = draft.move(ids[31], by: -1)
        #expect(moved && Array(draft.commandIDs.suffix(2)) == [ids[31], ids[30]])
        let removed = draft.select(ids[0], selected: false)
        let added = draft.select("utility.overflow", selected: true)
        #expect(removed && added)
        #expect(draft.commandIDs.first == ids[1] && draft.commandIDs.last == "utility.overflow")
        let list = draft.commandIDs; draft.actionFilter = "does not match"
        #expect(draft.commandIDs == list)
    }

    @Test func unavailableReferencesStayUntilExplicitRemovalAndSaveIsAtomic() throws {
        try withStore { store, _, file in
            let original = try CommandCollection(name: "Synthetic missing", commandIDs: [order[0], "utility.missing", order[2]])
            var configuration = store.configuration; configuration.collections = [original]
            #expect(store.commitSettingsConfiguration(configuration))
            let bytes = try Data(contentsOf: file)
            let session = WorkspaceSession(); session.editCollection(original)
            session.collectionDraft.actionFilter = "No match"
            #expect(!session.saveCollection(in: store))
            #expect(session.collectionDraft.commandIDs == original.commandIDs)
            #expect(try Data(contentsOf: file) == bytes)
            session.collectionDraft.removeUnavailable(availableIDs: Set(store.collectionActions.map(\.id)))
            #expect(session.collectionDraft.commandIDs == [order[0], order[2]])
            #expect(session.saveCollection(in: store))
            #expect(store.configuration.collections.first?.commandIDs == [order[0], order[2]])
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func failedWriteKeepsIdentityNameOrderFilterAndExactDiskBytes(failure: InterfaceWriteRelay.Failure) throws {
        try withStore { store, relay, file in
            let original = try add("Synthetic A", to: store)
            var bytes = try Data(contentsOf: file); bytes.append(0x0A); try bytes.write(to: file)
            let session = WorkspaceSession(); session.editCollection(original)
            session.collectionDraft.name = "Synthetic unsaved"
            session.collectionDraft.actionFilter = "Synthetic filter"
            session.collectionDraft.choosingActions = true
            let moved = session.collectionDraft.move(order[0], by: 1)
            #expect(moved)
            let draft = session.collectionDraft
            relay.failure = failure
            #expect(!session.saveCollection(in: store))
            #expect(session.collectionDraft == draft && store.configuration.collections == [original])
            #expect(store.workspaceNoticeMessage == store.settingsNoticeMessage && !store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(session.saveCollection(in: store))
            #expect(session.collectionDraft == CollectionEditorDraft() && store.workspaceNotice.isEmpty)
        }
    }

    @Test func deletedTargetCannotReappearAndStaleBrowsingClearsOnlySelection() throws {
        try withStore { store, _, file in
            let original = try add("Synthetic A", to: store)
            let session = WorkspaceSession(); session.editCollection(original); session.selectedCollectionID = original.id
            let draft = session.collectionDraft
            store.removeCollection(original.id)
            let bytes = try Data(contentsOf: file)
            session.reconcileCollectionSelection(in: store)
            #expect(session.selectedCollectionID == nil && session.collectionDraft == draft)
            #expect(!session.saveCollection(in: store))
            #expect(store.configuration.collections.isEmpty && session.collectionDraft == draft)
            #expect(try Data(contentsOf: file) == bytes)
            session.newCollection(); session.collectionDraft.name = "Synthetic recreated explicitly"
            #expect(session.saveCollection(in: store))
            #expect(store.configuration.collections.first?.id != original.id)
        }
    }

    @Test func collectionCapacityAllowsEditsAndNestedReferencesAreRejected() throws {
        try withStore { store, _, file in
            var configuration = store.configuration
            configuration.collections = try (0..<32).map { try CommandCollection(name: "Synthetic \($0)", commandIDs: order) }
            #expect(store.commitSettingsConfiguration(configuration))
            let bytes = try Data(contentsOf: file)
            let session = WorkspaceSession(); session.collectionDraft.name = "Synthetic overflow"
            #expect(!session.saveCollection(in: store) && !store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: file) == bytes)
            let original = try #require(configuration.collections.first)
            session.editCollection(original); session.collectionDraft.name = "Synthetic edit at capacity"
            #expect(session.saveCollection(in: store) && store.configuration.collections.count == 32)
            session.editCollection(try #require(store.configuration.collections.first))
            session.collectionDraft.commandIDs = ["collection." + original.id.uuidString]
            let nestedDraft = session.collectionDraft
            let saved = try Data(contentsOf: file)
            #expect(store.collectionAction(nestedDraft.commandIDs[0]) == nil)
            #expect(!session.saveCollection(in: store) && session.collectionDraft == nestedDraft)
            #expect(try Data(contentsOf: file) == saved)
        }
    }

    @Test func targetDependentWindowUtilitiesAreUnavailableInCollections() throws {
        try withStore { store, _, file in
            _ = try add("Synthetic A", to: store)
            let bytes = try Data(contentsOf: file)
            let layouts = store.catalog.filter { $0.payload.hasPrefix("window-layout.") }
            let windowCommands = store.catalog.filter { $0.payload.hasPrefix("window-command.") }
            #expect(!layouts.isEmpty && !windowCommands.isEmpty)
            for action in layouts + windowCommands {
                #expect(store.collectionAction(action.id) == nil)
                #expect(!store.collectionActions.contains { $0.id == action.id })
                #expect(!store.saveCollection(id: nil, name: "Synthetic invalid window group", commandIDs: [action.id]))
            }
            #expect(try Data(contentsOf: file) == bytes)
            #expect(store.configuration.collections.count == 1)
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func rejectedRemovalIsVisibleAndPreservesSavedCollectionsAndDraft(failure: InterfaceWriteRelay.Failure) throws {
        try withStore { store, relay, file in
            let collection = try add("Synthetic A", to: store)
            let session = WorkspaceSession(); session.editCollection(collection); session.selectedCollectionID = collection.id
            let draft = session.collectionDraft, bytes = try Data(contentsOf: file)
            relay.failure = failure
            #expect(!store.removeCollection(collection.id))
            session.reconcileCollectionSelection(in: store)
            #expect(session.selectedCollectionID == collection.id && session.collectionDraft == draft)
            #expect(store.configuration.collections == [collection] && !store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func collectionAIActionsOpenExplicitEmptyDraftsWithoutClipboardOrRequests() async throws {
        var reads = 0
        let fixture = try RetentionFixture(allowContextCapture: true, reader: { reads += 1; return "Synthetic clipboard must stay unread" })
        do {
            let store = fixture.store
            var launcherCallbacks = 0, opened: [UUID] = []
            store.onAIAction = { _, _ in launcherCallbacks += 1 }
            store.onOpenWorkspace = { if case .ai(let id) = $0 { opened.append(id) } }
            for source in AIInputSource.allCases {
                var action = AIActionPreset(name: "Synthetic collection AI", prompt: "Summarize synthetic input")
                action.input = source
                #expect(store.saveAction(action))
                store.runCollectionAction("ai." + action.id.uuidString)
                let draft = try #require(opened.last.flatMap { store.drafts[$0] })
                #expect(draft.actionID == action.id && draft.input.isEmpty && draft.source == .manual && draft.sourceTarget == nil)
            }
            #expect(opened.count == 3 && reads == 0 && launcherCallbacks == 0)
            #expect(store.tasks.isEmpty && store.taskHandles.isEmpty)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test func explicitSavedCommandShowsItsTaskAndCompletesInTheWorkspace() async throws {
        let fixture = try RetentionFixture()
        do {
            let store = fixture.store
            let command = SavedCommand(name: "Synthetic collection command", executable: "/usr/bin/printf", arguments: ["Synthetic collection output"], workingDirectory: fixture.directory.path)
            #expect(store.saveCommand(command))
            var openedTask: UUID?
            store.onOpenWorkspace = { if case .tasks(let id) = $0 { openedTask = id } }
            store.runCollectionAction("command." + command.id.uuidString)
            let id = try #require(openedTask)
            try await storeEventually { store.tasks.first(where: { $0.id == id })?.finishedAt != nil && store.taskHandles[id] == nil }
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.output == "Synthetic collection output" && task.exitCode == 0)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }
}
