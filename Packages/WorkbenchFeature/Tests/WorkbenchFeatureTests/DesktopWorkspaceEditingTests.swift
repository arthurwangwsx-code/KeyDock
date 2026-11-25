import Foundation
import Testing
import CommandCore
import MacAdapters
@testable import WorkbenchFeature

@MainActor private final class WorkspaceWriteFault {
    var stage: ArchiveStoreFaultStage?
    func invoke(_ stage: ArchiveStoreFaultStage) throws {
        if self.stage == stage { self.stage = nil; throw CocoaError(.fileWriteUnknown) }
    }
}

@Suite(.serialized) @MainActor struct DesktopWorkspaceEditingTests {
    private let appA = "app./Applications/SyntheticA.app", appB = "app./Applications/SyntheticB.app"
    private func withStore(_ body: (WorkbenchModel, WorkspaceWriteFault, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-WorkspaceEditing-" + UUID().uuidString)
        let directory = root.appendingPathComponent("profile"), fault = WorkspaceWriteFault()
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in Issue.record("Unexpected clipboard write") }, clipboardChangeCount: { 0 }, clipboardReader: { Issue.record("Unexpected clipboard read"); return nil },
            credentialReader: { _ in Issue.record("Unexpected credentials"); return nil }, credentialWriter: { _,_ in Issue.record("Unexpected credentials") },
            desktopWorkspaceFaultHook: fault.invoke, applicationCatalog: ApplicationCatalog(roots: []),
            applicationLauncher: { _ in Issue.record("Unexpected application launch"); throw CocoaError(.featureUnsupported) }, languageApplier: { _ in })
        store.desktop.applicationCatalog.stop()
        store.desktop.applicationCatalog.onChange?([CommandItem(id: appA, title: "Synthetic A", kind: .application, payload: "/Applications/SyntheticA.app"),CommandItem(id: appB, title: "Synthetic B", kind: .application, payload: "/Applications/SyntheticB.app")])
        do { try await body(store,fault,directory); await store.shutdownAndWait(); try? FileManager.default.removeItem(at: root) }
        catch { await store.shutdownAndWait(); try? FileManager.default.removeItem(at: root); throw error }
    }
    private func prepare(in session: SettingsSession, store: WorkbenchModel) throws -> DesktopWorkspaceEditorDraft {
        session.beginDesktopWorkspace(in: store)
        let draft = try #require(session.desktopWorkspaceEditor)
        draft.name = "Synthetic workspace"; draft.rows[0].applicationID = appA
        return draft
    }
    @Test func definitionEditingPreservesOrderAndAdvancesOnlyForRealChanges() async throws {
        try await withStore { store, fault, directory in
            let session = SettingsSession(store: store), draft = try prepare(in: session, store: store)
            draft.addRow(); draft.rows[1].applicationID = appB; draft.moveRow(draft.rows[1].id, by: -1)
            #expect(session.saveDesktopWorkspaceEdit(draft.id, in: store))
            let saved = try #require(store.desktopWorkspaces.first)
            #expect(saved.entries.map(\.applicationID) == [appB,appA] && saved.revision == 1)
            #expect(session.desktopWorkspaceEditor == nil && store.tasks.isEmpty)
            let bytes = try Data(contentsOf: directory.appendingPathComponent("desktop-workspaces.json"))
            session.beginDesktopWorkspace(saved, in: store)
            let edit = try #require(session.desktopWorkspaceEditor)
            fault.stage = .beforeCandidateWrite
            #expect(session.saveDesktopWorkspaceEdit(edit.id, in: store))
            #expect(fault.stage == .beforeCandidateWrite && store.desktopWorkspaces.first?.revision == 1)
            #expect(try Data(contentsOf: directory.appendingPathComponent("desktop-workspaces.json")) == bytes)
            fault.stage = nil
            session.beginDesktopWorkspace(saved, in: store)
            let changed = try #require(session.desktopWorkspaceEditor)
            changed.name = "Synthetic workspace edited"
            #expect(session.saveDesktopWorkspaceEdit(changed.id, in: store))
            #expect(store.desktopWorkspaces.first?.revision == 2)
        }
    }
    @Test(arguments: [ArchiveStoreFaultStage.beforeCandidateWrite,.afterCommit])
    func failedSaveKeepsDraftRowsAndExactFile(stage: ArchiveStoreFaultStage) async throws {
        try await withStore { store, fault, directory in
            let session = SettingsSession(store: store), initial = try prepare(in: session, store: store)
            #expect(session.saveDesktopWorkspaceEdit(initial.id, in: store))
            let saved = try #require(store.desktopWorkspaces.first), file = directory.appendingPathComponent("desktop-workspaces.json"), bytes = try Data(contentsOf: file)
            session.beginDesktopWorkspace(saved, in: store)
            let draft = try #require(session.desktopWorkspaceEditor); draft.name = "Synthetic unsaved name"
            draft.addRow(); draft.rows[1].applicationID = appB; let rows = draft.rows
            fault.stage = stage
            #expect(!session.saveDesktopWorkspaceEdit(draft.id, in: store))
            #expect(session.desktopWorkspaceEditor === draft && draft.rows == rows && draft.name == "Synthetic unsaved name")
            #expect(!draft.notice.rendered().isEmpty && store.desktopWorkspaces == [saved])
            #expect(try Data(contentsOf: file) == bytes)
            #expect(session.saveDesktopWorkspaceEdit(draft.id, in: store))
            #expect(store.desktopWorkspaces.first?.revision == 2)
        }
    }
    @Test func staleEditsCannotOverwriteOrResurrectDeletedDefinitions() async throws {
        try await withStore { store, _, _ in
            let session = SettingsSession(store: store), initial = try prepare(in: session, store: store)
            #expect(session.saveDesktopWorkspaceEdit(initial.id, in: store))
            let saved = try #require(store.desktopWorkspaces.first)
            session.beginDesktopWorkspace(saved, in: store); let draft = try #require(session.desktopWorkspaceEditor)
            let changed = try SavedDesktopWorkspace(id: saved.id, revision: saved.revision, name: "Synthetic changed elsewhere", entries: saved.entries)
            #expect(store.saveDesktopWorkspace(changed, expectedRevision: 1))
            draft.name = "Synthetic stale edit"
            #expect(!session.saveDesktopWorkspaceEdit(draft.id, in: store) && session.desktopWorkspaceEditor === draft)
            let current = try #require(store.desktopWorkspaces.first)
            #expect(!store.removeDesktopWorkspace(saved) && store.removeDesktopWorkspace(current))
            #expect(!session.saveDesktopWorkspaceEdit(draft.id, in: store) && store.desktopWorkspaces.isEmpty)
        }
    }
    @Test func invalidAndUnavailableDraftsStayEditableWithoutLaunchingAnything() async throws {
        try await withStore { store, _, _ in
            let session = SettingsSession(store: store), draft = try prepare(in: session, store: store)
            draft.name = String(repeating: "中", count: 54)
            #expect(!session.saveDesktopWorkspaceEdit(draft.id, in: store))
            #expect(session.desktopWorkspaceEditor === draft && !draft.notice.rendered().isEmpty)
            draft.name = "Synthetic valid"; #expect(session.saveDesktopWorkspaceEdit(draft.id, in: store))
            let saved = try #require(store.desktopWorkspaces.first)
            store.desktop.applicationCatalog.onChange?([])
            session.beginDesktopWorkspace(saved, in: store); let existing = try #require(session.desktopWorkspaceEditor)
            existing.name = "Synthetic preserved unavailable target"
            #expect(session.saveDesktopWorkspaceEdit(existing.id, in: store))
            session.beginDesktopWorkspace(in: store); let fresh = try #require(session.desktopWorkspaceEditor)
            fresh.name = "Synthetic unavailable new"; fresh.rows[0].applicationID = appA
            #expect(!session.saveDesktopWorkspaceEdit(fresh.id, in: store))
            #expect(session.desktopWorkspaceEditor === fresh && store.tasks.isEmpty)
        }
    }
    @Test func lateButtonsAndOtherEditorsCannotChangeTheCurrentPresentation() async throws {
        try await withStore { store, _, _ in
            let session = SettingsSession(store: store), first = try prepare(in: session, store: store)
            session.beginNewCommand(); session.beginNewAction(); session.prepareRemoval(.aiAction(UUID()), in: store)
            #expect(session.editedCommand == nil && session.editedAction == nil && session.savedItemRemoval == nil)
            session.pane = .general; session.pane = .desktopWorkspaces
            #expect(session.desktopWorkspaceEditor === first && first.rows[0].applicationID == appA)
            session.cancelDesktopWorkspaceEdit(first.id)
            let second = try prepare(in: session, store: store)
            #expect(!session.saveDesktopWorkspaceEdit(first.id, in: store))
            session.cancelDesktopWorkspaceEdit(first.id)
            #expect(session.desktopWorkspaceEditor === second && store.desktopWorkspaces.isEmpty)
        }
    }
    @Test func profilesHaveDirectCatalogShortcutsAndReferencesBlockDeletion() async throws {
        try await withStore { store, _, _ in
            let session = SettingsSession(store: store), draft = try prepare(in: session, store: store)
            #expect(session.saveDesktopWorkspaceEdit(draft.id, in: store))
            let value = try #require(store.desktopWorkspaces.first), manager = try #require(store.catalog.first { $0.id == "utility.desktop-workspaces" })
            #expect(store.catalog.contains { $0.id == value.commandID })
            let profile = try #require(store.catalog.first { $0.id == value.commandID })
            #expect(store.isDesktopCommand(profile.id) && ShortcutCategory.windows.contains(profile) && !ShortcutCategory.tools.contains(profile))
            var desktopInvocation: String?; store.onDesktopAction = { item, _ in desktopInvocation = item.id }
            store.desktopShortcut(profile.id); #expect(desktopInvocation == profile.id && store.tasks.isEmpty)
            #expect(ShortcutCategory.windows.contains(manager) && !ShortcutCategory.tools.contains(manager))
            var opened: SettingsPane?; store.onOpenSettings = { opened = $0 }
            store.performCommand(id: manager.id)
            #expect(opened == .desktopWorkspaces && store.tasks.isEmpty)
            store.onShortcutConfigurationChanged = { _ in }
            let registered = store.setShortcut(HotkeyBinding(keyCode: 2), for: value.commandID)
            #expect(registered)
            var config = store.configuration; config.commandShortcuts[value.commandID] = .init(keyCode: 2)
            #expect(ShortcutPlan.entries(config).contains { $0.commandID == value.commandID })
            store.onShortcutConfigurationChanged = { _ in }
            #expect(store.setShortcut(.init(keyCode: 3), for: manager.id))
            #expect(store.directShortcuts.contains { $0.0 == manager.id })
            #expect(!store.removeDesktopWorkspace(value))
            #expect(store.setShortcut(nil, for: value.commandID))
            store.configuration.preferences.favorites.insert(value.commandID)
            #expect(!store.removeDesktopWorkspace(value))
            store.configuration.preferences.favorites.remove(value.commandID)
            #expect(store.removeDesktopWorkspace(value))
        }
    }

    @Test func workspaceAliasCanBeClearedPersistentlyBeforeRemovingDefinition() async throws {
        try await withStore { store, _, directory in
            let session = SettingsSession(store: store), draft = try prepare(in: session, store: store)
            #expect(session.saveDesktopWorkspaceEdit(draft.id, in: store))
            let value = try #require(store.desktopWorkspaces.first)
            store.setAlias("synthetic-desk", for: value.commandID)
            #expect(!store.removeDesktopWorkspace(value))
            store.setAlias("", for: value.commandID)
            let persisted = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("configuration.json")))
            #expect(persisted.preferences.aliases[value.commandID] == nil && store.configuration.preferences.aliases[value.commandID] == nil)
            let removed = store.removeDesktopWorkspace(value)
            #expect(removed && store.desktopWorkspaces.isEmpty)
        }
    }

    @Test(arguments: ["", "   ", "\n"])
    func legacyBlankAliasDoesNotBlockDefinitionRemoval(blank: String) async throws {
        try await withStore { store, _, _ in
            let session = SettingsSession(store: store), draft = try prepare(in: session, store: store)
            #expect(session.saveDesktopWorkspaceEdit(draft.id, in: store))
            let value = try #require(store.desktopWorkspaces.first)
            store.configuration.preferences.aliases[value.commandID] = blank; store.save()
            let removed = store.removeDesktopWorkspace(value)
            #expect(removed && store.desktopWorkspaces.isEmpty)
        }
    }

    @Test func staleProfileShortcutUsesVisibleSettingsFailureWithoutGenericLauncherCapture() async throws {
        try await withStore { store, _, _ in
            var pane: SettingsPane?, routed = false
            store.onOpenSettings = { pane = $0 }; store.onDesktopAction = { _,_ in routed = true }
            store.performDesktopWorkspaceShortcut(id: "desktop-workspace." + UUID().uuidString)
            #expect(pane == .desktopWorkspaces && !routed && !store.settingsNotice.isEmpty && store.tasks.isEmpty)
        }
    }
    @Test func saveFailureDoesNotCancelLiveSnapshotButSuccessfulRevisionDoes() async throws {
        try await withStore { store, fault, _ in
            let session = SettingsSession(store: store), draft = try prepare(in: session, store: store)
            #expect(session.saveDesktopWorkspaceEdit(draft.id, in: store))
            let original = try #require(store.desktopWorkspaces.first), item = try #require(store.catalog.first { $0.id == original.commandID })
            let run = UUID(), group = DesktopOperationGroup()
            store.desktopWorkspaceGroups[run] = (original.id,group)
            let edited = try SavedDesktopWorkspace(id: original.id, revision: original.revision, name: "Synthetic new revision", entries: original.entries)
            fault.stage = .afterCommit
            #expect(!store.saveDesktopWorkspace(edited, expectedRevision: original.revision) && group.isCurrent)
            #expect(store.catalog.contains(item))
            #expect(store.saveDesktopWorkspace(edited, expectedRevision: original.revision) && !group.isCurrent)
            #expect(store.catalog.first { $0.id == original.commandID }?.objectRevision != item.objectRevision)
            store.desktopWorkspaceGroups[run] = nil
        }
    }

    @Test(arguments: ["replace","remove","directory"])
    func unchangedSaveCannotHideExternalFileOrDirectoryDrift(change: String) async throws {
        try await withStore { store, _, directory in
            let session = SettingsSession(store: store), initial = try prepare(in: session, store: store)
            #expect(session.saveDesktopWorkspaceEdit(initial.id, in: store))
            let saved = try #require(store.desktopWorkspaces.first), file = directory.appendingPathComponent("desktop-workspaces.json")
            let bytes = try Data(contentsOf: file)
            session.beginDesktopWorkspace(saved, in: store)
            let draft = try #require(session.desktopWorkspaceEditor)
            let external: Data?
            switch change {
            case "replace": external = try DesktopWorkspaceArchive(workspaces: [SavedDesktopWorkspace(name: "Synthetic external", entries: saved.entries)]).encoded(); try external?.write(to: file, options: .atomic)
            case "remove": external = nil; try FileManager.default.removeItem(at: file)
            default:
                external = bytes
                try FileManager.default.moveItem(at: directory, to: directory.deletingLastPathComponent().appendingPathComponent("previous-profile"))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try bytes.write(to: file)
            }
            #expect(!session.saveDesktopWorkspaceEdit(draft.id, in: store))
            #expect(session.desktopWorkspaceEditor === draft && !store.desktopWorkspacesWritable)
            #expect(!draft.notice.rendered().isEmpty && store.desktopWorkspaces == [saved])
            #expect((try? Data(contentsOf: file)) == external)
        }
    }
}
