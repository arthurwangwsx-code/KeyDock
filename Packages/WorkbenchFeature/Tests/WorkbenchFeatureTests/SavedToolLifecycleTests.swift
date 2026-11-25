import Foundation
import Testing
import CommandCore
import MacAdapters
import AutomationCore
@testable import WorkbenchFeature

enum SavedToolKind: CaseIterable, Sendable { case snippet, web, collection }
enum SavedToolDraftSnapshot: Equatable {
    case snippet(SnippetEditorDraft), web(WebActionEditorDraft), collection(CollectionEditorDraft)
}

@MainActor final class SavedToolFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-SavedTool-" + UUID().uuidString)
    let relay = InterfaceWriteRelay()
    let store: WorkbenchModel
    var copies: [String] = []
    var clipboardReads = 0
    var runtime: [ShortcutPlanEntry] = []
    var registrationCalls = 0
    var failRegistration = false
    var failRestoration = false
    init() throws {
        var writer: ((String) -> Void)?, reader: (() -> Void)?
        store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { writer?($0) }, clipboardChangeCount: { 0 }, clipboardReader: { reader?(); return nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in }, configurationWriter: relay.write,
            applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
        writer = { [weak self] in self?.copies.append($0) }; reader = { [weak self] in self?.clipboardReads += 1 }
        runtime = ShortcutPlan.entries(store.configuration)
        store.onShortcutConfigurationChanged = { [weak self] configuration in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            registrationCalls += 1
            if failRegistration || (failRestoration && registrationCalls == 2) { throw HotkeyRegistrationError(status: -50) }
            runtime = ShortcutPlan.entries(configuration)
        }
    }
    var file: URL { directory.appendingPathComponent("configuration.json") }
    func add(_ kind: SavedToolKind) throws -> SavedItemTarget {
        switch kind {
        case .snippet:
            #expect(store.saveSnippet(name: "Synthetic é", text: "Synthetic snippet body"))
            return .snippet(try #require(store.configuration.snippets.last?.id))
        case .web:
            #expect(store.saveWebAction(id: nil, name: "Synthetic é", template: "https://example.com/search?q={query}"))
            return .webAction(try #require(store.configuration.webActions.last?.id))
        case .collection:
            #expect(store.saveCollection(id: nil, name: "Synthetic é", commandIDs: ["utility.tools"]))
            return .collection(try #require(store.configuration.collections.last?.id))
        }
    }
    func edit(_ target: SavedItemTarget, in session: WorkspaceSession) throws {
        switch target {
        case .snippet(let id): session.editSnippet(try #require(store.configuration.snippets.first { $0.id == id }))
        case .webAction(let id): session.editWebAction(try #require(store.configuration.webActions.first { $0.id == id }))
        case .collection(let id): session.editCollection(try #require(store.configuration.collections.first { $0.id == id }))
        default: throw CocoaError(.fileReadUnknown)
        }
    }
    func snapshot(_ kind: SavedToolKind, _ session: WorkspaceSession) -> SavedToolDraftSnapshot {
        switch kind { case .snippet: .snippet(session.snippetDraft); case .web: .web(session.webActionDraft); case .collection: .collection(session.collectionDraft) }
    }
    func save(_ kind: SavedToolKind, _ session: WorkspaceSession) -> Bool {
        switch kind { case .snippet: session.saveSnippet(in: store); case .web: session.saveWebAction(in: store); case .collection: session.saveCollection(in: store) }
    }
    func new(_ kind: SavedToolKind, _ session: WorkspaceSession) {
        switch kind {
        case .snippet: session.newSnippet(); session.snippetDraft.name = "Synthetic new"; session.snippetDraft.text = "Synthetic new body"
        case .web: session.newWebAction(); session.webActionDraft.name = "Synthetic new"; session.webActionDraft.urlTemplate = "https://example.com/new"
        case .collection: session.newCollection(); session.collectionDraft.name = "Synthetic new"; session.collectionDraft.commandIDs = ["utility.tools"]
        }
    }
    func updateBytes(_ target: SavedItemTarget) throws {
        switch target {
        case .snippet(let id): #expect(store.saveSnippet(id: id, name: "Synthetic e\u{301}", text: "Synthetic snippet body"))
        case .webAction(let id): #expect(store.saveWebAction(id: id, name: "Synthetic e\u{301}", template: "https://example.com/search?q={query}"))
        case .collection(let id): #expect(store.saveCollection(id: id, name: "Synthetic e\u{301}", commandIDs: ["utility.tools"]))
        default: throw CocoaError(.fileReadUnknown)
        }
    }
    func cleanup() async { await store.shutdownAndWait(); try? FileManager.default.removeItem(at: directory) }
}

/// 合成定义与真实配置文件／补偿；从不注册OS热键、打开URL或读取个人剪贴板。
@Suite(.serialized) @MainActor struct SavedToolLifecycleTests {
    private func withFixture(_ body: (SavedToolFixture) async throws -> Void) async throws {
        let fixture = try SavedToolFixture()
        do { try await body(fixture); await fixture.cleanup() } catch { await fixture.cleanup(); throw error }
    }

    @Test(arguments: SavedToolKind.allCases)
    func removalCleansExactPreferencesAndShortcutInOneReloadableTransaction(kind: SavedToolKind) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(kind)
            let neighbor = target.commandID + ".other"
            var next = store.configuration
            for id in [target.commandID, neighbor] {
                next.preferences.favorites.insert(id); next.preferences.aliases[id] = "Synthetic alias"
                next.preferences.recent[id] = Date(timeIntervalSince1970: 1)
            }
            next.commandShortcuts[target.commandID] = HotkeyBinding(keyCode: 2)
            next.commandShortcuts[neighbor] = HotkeyBinding(keyCode: 3)
            #expect(store.commitShortcutConfiguration(next))
            let session = WorkspaceSession(); try fixture.edit(target, in: session)
            let draft = fixture.snapshot(kind, session)
            session.prepareToolRemoval(target, in: store)
            #expect(session.confirmToolRemoval(try #require(session.savedToolRemoval?.review.id), in: store))
            #expect(session.savedToolRemoval == nil && fixture.snapshot(kind, session) == draft)
            #expect(!store.catalog.contains { $0.id == target.commandID })
            #expect(!fixture.runtime.contains { $0.commandID == target.commandID })
            #expect(store.configuration.commandShortcuts[target.commandID] == nil)
            #expect(!store.configuration.preferences.favorites.contains(target.commandID))
            #expect(store.configuration.preferences.aliases[target.commandID] == nil && store.configuration.preferences.recent[target.commandID] == nil)
            #expect(store.configuration.commandShortcuts[neighbor] != nil && store.configuration.preferences.favorites.contains(neighbor))
            #expect(store.configuration.preferences.aliases[neighbor] != nil && store.configuration.preferences.recent[neighbor] != nil)
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fixture.file))
            #expect(decoded.commandShortcuts[target.commandID] == nil && decoded.preferences.aliases[target.commandID] == nil)
            #expect(decoded.snippets == store.configuration.snippets && decoded.webActions == store.configuration.webActions && decoded.collections == store.configuration.collections)
        }
    }

    @Test(arguments: SavedToolKind.allCases)
    func removedEditsStayUnsavedAndOnlyExplicitNewCreatesANewIdentity(kind: SavedToolKind) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(kind), session = WorkspaceSession()
            try fixture.edit(target, in: session); let draft = fixture.snapshot(kind, session)
            #expect(store.removeSavedItem(try #require(store.reviewSavedItemRemoval(target))))
            let bytes = try Data(contentsOf: fixture.file)
            #expect(!fixture.save(kind, session) && fixture.snapshot(kind, session) == draft)
            #expect(!store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            if case .snippet(let id) = target { #expect(!store.saveSnippet(id: id, name: "Synthetic old", text: "Synthetic cannot revive")) }
            fixture.new(kind, session); #expect(fixture.save(kind, session))
            #expect(!store.catalog.contains { $0.id == target.commandID })
            #expect(store.catalog.contains { $0.title == "Synthetic new" })
        }
    }

    @Test(arguments: SavedToolKind.allCases)
    func byteDifferentExternalEditRejectsOldSaveAndOldRemoval(kind: SavedToolKind) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(kind), session = WorkspaceSession()
            try fixture.edit(target, in: session); let draft = fixture.snapshot(kind, session)
            session.prepareToolRemoval(target, in: store)
            let presentation = try #require(session.savedToolRemoval), old = presentation.review
            try fixture.updateBytes(target)
            #expect(old.fingerprint != store.reviewSavedItemRemoval(target)?.fingerprint)
            let bytes = try Data(contentsOf: fixture.file)
            #expect(!session.confirmToolRemoval(old.id, in: store))
            #expect(session.savedToolRemoval?.id == presentation.id && fixture.snapshot(kind, session) == draft)
            session.refreshToolRemoval(presentation.id, in: store)
            #expect(presentation.id == session.savedToolRemoval?.id && presentation.review.id != old.id)
            #expect(!session.confirmToolRemoval(old.id, in: store))
            session.cancelToolRemoval(presentation.id)
            #expect(!fixture.save(kind, session) && fixture.snapshot(kind, session) == draft)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            try fixture.edit(target, in: session)
            #expect(fixture.save(kind, session))
        }
    }

    @Test(arguments: [SavedToolKind.snippet, .web])
    func collectionReferencesAndLateChangesBlockDeletionWithoutCascading(kind: SavedToolKind) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(kind)
            let old = try #require(store.reviewSavedItemRemoval(target))
            #expect(store.saveCollection(id: nil, name: "Synthetic reference", commandIDs: [target.commandID]))
            let bytes = try Data(contentsOf: fixture.file)
            #expect(!store.removeSavedItem(old))
            let current = try #require(store.reviewSavedItemRemoval(target))
            #expect(current.dependencies.count == 1 && current.dependencies.first?.name == "Synthetic reference")
            #expect(!store.removeSavedItem(current))
            #expect(try Data(contentsOf: fixture.file) == bytes)
            let collectionID = try #require(store.configuration.collections.first?.id)
            #expect(store.removeCollection(collectionID))
            #expect(!store.removeSavedItem(current))
            #expect(store.removeSavedItem(try #require(store.reviewSavedItemRemoval(target))))
        }
    }

    @Test(arguments: SavedToolKind.allCases, [InterfaceWriteRelay.Failure.before, .after])
    func failedDeleteRestoresDiskRuntimeAndDraftAndKeepsReview(kind: SavedToolKind, failure: InterfaceWriteRelay.Failure) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(kind), session = WorkspaceSession()
            #expect(store.setShortcut(HotkeyBinding(keyCode: 2), for: target.commandID))
            try fixture.edit(target, in: session)
            session.prepareToolRemoval(target, in: store)
            let presentation = try #require(session.savedToolRemoval), draft = fixture.snapshot(kind, session)
            let bytes = try Data(contentsOf: fixture.file), runtime = fixture.runtime
            fixture.relay.failure = failure
            #expect(!session.confirmToolRemoval(presentation.review.id, in: store))
            #expect(session.savedToolRemoval?.id == presentation.id && fixture.snapshot(kind, session) == draft)
            #expect(fixture.runtime == runtime && !store.shortcutsUnavailable && !store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(session.confirmToolRemoval(presentation.review.id, in: store))
        }
    }

    @Test func registrationAndRestorationFailuresAreVisibleAndKeepSavedTool() async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(.snippet)
            #expect(store.setShortcut(HotkeyBinding(keyCode: 2), for: target.commandID))
            let review = try #require(store.reviewSavedItemRemoval(target)), bytes = try Data(contentsOf: fixture.file), runtime = fixture.runtime
            fixture.failRegistration = true
            #expect(!store.removeSavedItem(review) && fixture.runtime == runtime)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            fixture.failRegistration = false; fixture.registrationCalls = 0; fixture.failRestoration = true; fixture.relay.failure = .after
            #expect(!store.removeSavedItem(review) && store.shortcutsUnavailable)
            #expect(store.workspaceNoticeMessage == noticeKey("Shortcut changes could not be saved and rollback was incomplete. Check the saved shortcuts before retrying."))
            #expect(store.catalog.contains { $0.id == target.commandID })
        }
    }

    @Test func reviewIdentitiesAndWorkflowInputCannotReplaceEachOtherOrDrafts() async throws {
        try await withFixture { fixture in
            let store = fixture.store, first = try fixture.add(.snippet), second = try fixture.add(.web), session = WorkspaceSession()
            try fixture.edit(first, in: session); let draft = session.snippetDraft
            session.prepareToolRemoval(first, in: store)
            let old = try #require(session.savedToolRemoval)
            session.newSnippet(); session.newWebAction(); session.newCollection()
            #expect(session.snippetDraft == draft)
            session.cancelToolRemoval(old.id); session.prepareToolRemoval(second, in: store)
            let current = try #require(session.savedToolRemoval)
            #expect(!session.confirmToolRemoval(old.review.id, in: store)); session.cancelToolRemoval(old.id)
            #expect(session.savedToolRemoval?.id == current.id)
            let workflow = WorkflowDefinition(name: "Synthetic modal", steps: [.init(operation: .transform(.trim))])
            #expect(store.saveWorkflow(workflow))
            #expect(!session.prepareWorkflowLaunch(workflow.id, in: store) && session.workflowLaunch == nil)
            session.cancelToolRemoval(current.id)
            #expect(session.prepareWorkflowLaunch(workflow.id, in: store))
            session.prepareToolRemoval(first, in: store)
            #expect(session.savedToolRemoval == nil && session.workflowLaunch != nil)
        }
    }

    @Test(arguments: SavedToolKind.allCases)
    func shortcutsAndStaleResultsUseFrozenIdentityWithoutClipboardInput(kind: SavedToolKind) async throws {
        try await withFixture { fixture in
            let store = fixture.store, target = try fixture.add(kind)
            var routes = 0
            store.onOpenWorkspace = { _ in routes += 1 }
            let invocation = try #require(store.prepareSavedToolShortcut(id: target.commandID))
            let item = try #require(store.catalog.first { $0.id == target.commandID })
            store.performCommand(invocation)
            #expect(fixture.clipboardReads == 0)
            #expect(fixture.copies == (kind == .snippet ? ["Synthetic snippet body"] : []))
            #expect(routes == (kind == .snippet ? 0 : 1))
            try fixture.updateBytes(target)
            let copies = fixture.copies, count = routes, bytes = try Data(contentsOf: fixture.file)
            store.performCommand(invocation); store.execute(item)
            #expect(fixture.copies == copies && routes == count && fixture.clipboardReads == 0)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(store.removeSavedItem(try #require(store.reviewSavedItemRemoval(target))))
            let removedBytes = try Data(contentsOf: fixture.file)
            #expect(store.prepareSavedToolShortcut(id: target.commandID) == nil)
            store.performCommand(invocation); store.execute(item)
            #expect(fixture.copies == copies && routes == count && fixture.clipboardReads == 0)
            #expect(store.configuration.preferences.recent[target.commandID] == nil)
            #expect(try Data(contentsOf: fixture.file) == removedBytes)
        }
    }
}
