import Foundation
import Testing
import CommandCore
import MacAdapters
@testable import WorkbenchFeature

/// 只使用合成配置目录与地址；不打开URL或读取个人凭据。
@Suite(.serialized) @MainActor struct WebActionEditingTests {
    private func withStore(_ body: (WorkbenchModel, InterfaceWriteRelay, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-WebEditing-" + UUID().uuidString)
        let relay = InterfaceWriteRelay()
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in }, configurationWriter: relay.write,
            applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        try body(store, relay, directory.appendingPathComponent("configuration.json"))
    }
    private func add(_ name: String, to store: WorkbenchModel) throws -> WebActionDefinition {
        #expect(store.saveWebAction(id: nil, name: name, template: "https://example.com/search?q={query}"))
        return try #require(store.configuration.webActions.last)
    }

    @Test(arguments: [false, true]) func useAndLauncherRoutingCannotTurnANewFormIntoAnEdit(route: Bool) throws {
        try withStore { store, _, _ in
            let original = try add("Synthetic A", to: store)
            let session = WorkspaceSession()
            if route { session.navigate(.web(original.id), store: store) }
            else { session.selectedWebActionID = original.id }
            session.webActionDraft.name = "Synthetic B"
            session.webActionDraft.urlTemplate = "https://example.com/b"
            #expect(session.saveWebAction(in: store))
            #expect(store.configuration.webActions.first == original)
            let second = try #require(store.configuration.webActions.last)
            #expect(second.id != original.id && second.name == "Synthetic B")
            #expect(session.selectedWebActionID == original.id)
            #expect(session.webActionDraft == WebActionEditorDraft())
            session.webActionDraft.name = "Synthetic C"
            session.webActionDraft.urlTemplate = "https://example.com/c"
            #expect(session.saveWebAction(in: store))
            #expect(Set(store.configuration.webActions.map(\.id)).count == 3)
            #expect(store.configuration.webActions.first == original)
        }
    }

    @Test func editingOneActionSurvivesUsingAnotherAndNavigatingAway() throws {
        try withStore { store, _, _ in
            let original = try add("Synthetic A", to: store)
            let other = try add("Synthetic B", to: store)
            let session = WorkspaceSession()
            session.editWebAction(original)
            session.webActionDraft.name = "Synthetic A edited"
            let draft = session.webActionDraft
            session.selectedWebActionID = other.id
            session.webQuery = "Synthetic query"
            session.navigate(.tasks(nil), store: store)
            session.navigate(.web(other.id), store: store)
            #expect(session.webActionDraft == draft)
            #expect(session.saveWebAction(in: store))
            #expect(store.configuration.webActions.count == 2)
            #expect(store.configuration.webActions.first { $0.id == original.id }?.name == draft.name)
            #expect(store.configuration.webActions.first { $0.id == other.id } == other)
            #expect(session.selectedWebActionID == other.id && session.webQuery == "Synthetic query")
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func rejectedPersistenceKeepsDraftAndOriginalConfigurationBytes(failure: InterfaceWriteRelay.Failure) throws {
        try withStore { store, relay, file in
            let original = try add("Synthetic A", to: store)
            var bytes = try Data(contentsOf: file); bytes.append(0x0A); try bytes.write(to: file)
            let session = WorkspaceSession(); session.editWebAction(original)
            session.webActionDraft.name = "Synthetic unsaved edit"
            let draft = session.webActionDraft
            relay.failure = failure
            #expect(!session.saveWebAction(in: store))
            #expect(session.webActionDraft == draft)
            #expect(store.configuration.webActions == [original])
            #expect(store.workspaceNoticeMessage == store.settingsNoticeMessage)
            #expect(!store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(session.saveWebAction(in: store))
            #expect(store.workspaceNotice.isEmpty)
            #expect(session.webActionDraft == WebActionEditorDraft())
        }
    }

    @Test func invalidDefinitionKeepsDraftAndSavedAction() throws {
        try withStore { store, _, file in
            let original = try add("Synthetic A", to: store)
            let bytes = try Data(contentsOf: file)
            let session = WorkspaceSession(); session.editWebAction(original)
            session.webActionDraft.urlTemplate = "javascript://example.com/"
            let draft = session.webActionDraft
            #expect(!session.saveWebAction(in: store))
            #expect(session.webActionDraft == draft)
            #expect(store.configuration.webActions == [original])
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func deletedEditTargetCannotBeResurrectedAndNewIsExplicit() throws {
        try withStore { store, _, file in
            let original = try add("Synthetic A", to: store)
            let session = WorkspaceSession(); session.editWebAction(original)
            let draft = session.webActionDraft
            store.removeWebAction(original.id)
            let bytes = try Data(contentsOf: file)
            #expect(!session.saveWebAction(in: store))
            #expect(session.webActionDraft == draft && store.configuration.webActions.isEmpty)
            #expect(!store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: file) == bytes)
            session.newWebAction()
            #expect(session.webActionDraft == WebActionEditorDraft())
            session.webActionDraft.name = draft.name
            session.webActionDraft.urlTemplate = draft.urlTemplate
            #expect(session.saveWebAction(in: store))
            #expect(store.configuration.webActions.count == 1)
            #expect(store.configuration.webActions.first?.id != original.id)
        }
    }

    @Test func fullListRejectsNewDraftButStillAllowsExplicitEdits() throws {
        try withStore { store, _, file in
            var configuration = store.configuration
            configuration.webActions = try (0..<100).map { try WebActionDefinition(name: "Synthetic \($0)", urlTemplate: "https://example.com/\($0)") }
            #expect(store.commitSettingsConfiguration(configuration))
            let bytes = try Data(contentsOf: file)
            let session = WorkspaceSession()
            session.webActionDraft.name = "Synthetic overflow"
            session.webActionDraft.urlTemplate = "https://example.com/overflow"
            let draft = session.webActionDraft
            #expect(!session.saveWebAction(in: store))
            #expect(session.webActionDraft == draft)
            #expect(store.configuration.webActions == configuration.webActions)
            #expect(!store.workspaceNotice.isEmpty)
            #expect(try Data(contentsOf: file) == bytes)
            session.editWebAction(try #require(configuration.webActions.first))
            session.webActionDraft.name = "Synthetic edited at capacity"
            #expect(session.saveWebAction(in: store))
            #expect(store.configuration.webActions.count == 100)
            #expect(store.configuration.webActions.first?.name == "Synthetic edited at capacity")
            #expect(store.workspaceNotice.isEmpty)
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func rejectedRemovalKeepsTheActionAndShowsWorkspaceFailure(failure: InterfaceWriteRelay.Failure) throws {
        try withStore { store, relay, file in
            let action = try add("Synthetic A", to: store)
            let bytes = try Data(contentsOf: file)
            relay.failure = failure
            #expect(!store.removeWebAction(action.id))
            #expect(store.configuration.webActions == [action])
            #expect(!store.workspaceNotice.isEmpty && store.workspaceNoticeMessage == store.settingsNoticeMessage)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
