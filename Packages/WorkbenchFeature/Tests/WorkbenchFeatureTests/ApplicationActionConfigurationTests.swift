import Foundation
import Testing
import CommandCore
import ExecutionCore
import MacAdapters
@testable import WorkbenchFeature

@MainActor private final class ApplicationConfigurationFixture {
    let directory: URL
    let action = try! SavedApplicationAction(name: "Synthetic hide", applicationID: "app./Synthetic.app", behavior: .hide)
    let relay = InterfaceWriteRelay()
    var writerHook: (() throws -> Void)?
    var legacy: URL { directory.appendingPathComponent("application-actions.json") }
    var configuration: URL { directory.appendingPathComponent("configuration.json") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ActionMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ApplicationActionArchive(actions: [action]).encoded().write(to: legacy)
    }
    func oldConfiguration(_ version: Int) throws {
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfiguration())) as? [String: Any])
        document["schemaVersion"] = version; document.removeValue(forKey: "savedApplicationActions")
        document["agents"] = (document["agents"] as! [[String: Any]]).map { value in var row = value; row.removeValue(forKey: "maxRunTokens"); return row }
        if version == 1 { document.removeValue(forKey: "aiModelSettings"); document.removeValue(forKey: "aiSettingsRevision") }
        try JSONSerialization.data(withJSONObject: document).write(to: configuration)
    }
    func model() throws -> WorkbenchModel {
        try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in },
            configurationWriter: { [self] data, url in try relay.write(data, to: url); try writerHook?() },
            applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
    }
    func cleanup(_ store: WorkbenchModel) async { await store.shutdownAndWait(); try? FileManager.default.removeItem(at: directory) }
}

@Suite(.serialized) @MainActor struct ApplicationActionConfigurationTests {
    @Test(arguments: [0, 1, 2]) func legacyIsReadOnlyUntilFirstSuccessfulConfigurationCommit(_ version: Int) async throws {
        let f = try ApplicationConfigurationFixture()
        if version > 0 { try f.oldConfiguration(version) }
        let raw = try Data(contentsOf: f.legacy)
        let store = try f.model()
        #expect(store.configuration.savedApplicationActions == nil && store.applicationActions == [f.action])
        #expect(store.applicationActionsWritable)
        let epoch = store.applicationActionsEpoch
        let lease = DesktopOperationLease(); try lease.begin(); store.desktopLeases[UUID()] = lease
        var next = store.configuration; next.appearance = "dark"
        #expect(store.commitSettingsConfiguration(next))
        #expect(store.configuration.savedApplicationActions == [f.action] && store.applicationActionsEpoch == epoch)
        #expect(lease.isCurrent && store.legacyApplicationActions == nil)
        #expect(try Data(contentsOf: f.legacy) == raw)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: f.configuration))
        #expect(decoded.schemaVersion == 4 && decoded.savedApplicationActions == [f.action])
        await store.shutdownAndWait()
        try Data("old-source-now-unreadable".utf8).write(to: f.legacy)
        let reopened = try f.model()
        #expect(reopened.applicationActions == [f.action] && reopened.applicationActionsWritable)
        await f.cleanup(reopened)
    }
    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after], [false, true])
    func failedFirstMigrationKeepsOldBytesMemoryAndLeases(failure: InterfaceWriteRelay.Failure, hadConfiguration: Bool) async throws {
        let f = try ApplicationConfigurationFixture(); if hadConfiguration { try f.oldConfiguration(2) }
        let original = hadConfiguration ? try Data(contentsOf: f.configuration) : nil
        let oldSource = try Data(contentsOf: f.legacy), store = try f.model()
        let epoch = store.applicationActionsEpoch
        let lease = DesktopOperationLease(); try lease.begin(); store.desktopLeases[UUID()] = lease
        f.relay.failure = failure
        var next = store.configuration; next.language = "en"
        #expect(!store.commitSettingsConfiguration(next))
        #expect(store.configuration.savedApplicationActions == nil && store.configuration.language == "system")
        #expect(store.applicationActions == [f.action] && store.applicationActionsEpoch == epoch && lease.isCurrent)
        #expect((try? Data(contentsOf: f.configuration)) == original)
        #expect(try Data(contentsOf: f.legacy) == oldSource)
        #expect(store.commitSettingsConfiguration(next))
        await f.cleanup(store)
    }
    @Test func unknownLegacyRemainsNullAndUnrelatedPreferencesCanBeSaved() async throws {
        let f = try ApplicationConfigurationFixture(); try Data("unconfirmed".utf8).write(to: f.legacy)
        let store = try f.model(), command = "application-action." + f.action.id.uuidString
        #expect(!store.applicationActionsWritable && store.applicationActions.isEmpty)
        var next = store.configuration; next.appearance = "dark"; next.preferences.favorites.insert(command)
        #expect(store.commitSettingsConfiguration(next))
        #expect(store.configuration.savedApplicationActions == nil && !store.applicationActionsWritable)
        #expect(!store.saveApplicationAction(f.action) && !store.hasDeletedToolPreferences)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.configuration)) as? [String: Any])
        #expect(object["savedApplicationActions"] is NSNull)
        let source = try await store.captureConfigurationExport(sections: [.shortcuts], sourceVersion: "synthetic")
        #expect(throws: ConfigurationExportError.unavailableSource("desktop")) {
            try ConfigurationExportProjection.make(source: source, sections: [.shortcuts])
        }
        next.preferences.favorites = []; #expect(store.commitSettingsConfiguration(next))
        let independent = try await store.captureConfigurationExport(sections: [.preferences], sourceVersion: "synthetic")
        _ = try ConfigurationExportProjection.make(source: independent, sections: [.preferences])
        #expect(try Data(contentsOf: f.legacy) == Data("unconfirmed".utf8))
        await f.cleanup(store)
    }
    @Test func exportDistinguishesCanonicalMissingReferencesFromUnselectedDefinitions() async throws {
        let f = try ApplicationConfigurationFixture(), store = try f.model()
        var next = store.configuration; next.savedApplicationActions = [f.action]
        next.preferences.favorites = ["application-action." + f.action.id.uuidString]
        #expect(store.commitSettingsConfiguration(next))
        let source = try await store.captureConfigurationExport(sections: [.shortcuts], sourceVersion: "synthetic")
        let partial = try ConfigurationExportProjection.make(source: source, sections: [.shortcuts])
        #expect(partial.unselectedDependencyCount == 1)
        next.savedApplicationActions = []; #expect(store.commitSettingsConfiguration(next))
        let empty = try await store.captureConfigurationExport(sections: [.shortcuts], sourceVersion: "synthetic")
        #expect(throws: ConfigurationExportError.invalidReference("shortcuts.favorites")) {
            try ConfigurationExportProjection.make(source: empty, sections: [.shortcuts])
        }
        await f.cleanup(store)
    }
    @Test func sourceChangedInsideWriterCompensatesConfigurationAndShortcutRegistration() async throws {
        let f = try ApplicationConfigurationFixture(); try f.oldConfiguration(2)
        let original = try Data(contentsOf: f.configuration), store = try f.model()
        var plans: [[ShortcutPlanEntry]] = []
        store.onShortcutConfigurationChanged = { plans.append(ShortcutPlan.entries($0)) }
        var next = store.configuration; next.launcherShortcut = nil
        f.writerHook = { [f] in f.writerHook = nil; try Data("external-new-source".utf8).write(to: f.legacy, options: .atomic) }
        #expect(!store.commitShortcutConfiguration(next))
        #expect(plans.count == 2 && plans.last == ShortcutPlan.entries(store.configuration))
        #expect(try Data(contentsOf: f.configuration) == original)
        #expect(store.configuration.savedApplicationActions == nil && !store.applicationActionsWritable && store.applicationActions.isEmpty)
        #expect(try Data(contentsOf: f.legacy) == Data("external-new-source".utf8))
        await f.cleanup(store)
    }
    @Test func removalChecksReferencesAndAtomicallyClearsOnlyExactPreferences() async throws {
        let f = try ApplicationConfigurationFixture(), store = try f.model()
        let id = "application-action." + f.action.id.uuidString, neighbor = "application-action." + UUID().uuidString
        var next = store.configuration; next.savedApplicationActions = [f.action]
        next.collections = [try .init(name: "Synthetic reference", commandIDs: [id])]
        next.commandShortcuts[id] = .init(); next.commandShortcuts[neighbor] = .init(keyCode: 96, modifiers: 0)
        next.preferences.favorites = [id, neighbor]; next.preferences.aliases = [id: "synthetic", neighbor: "keep"]
        next.preferences.recent = [id: Date(), neighbor: Date()]
        store.onShortcutConfigurationChanged = { _ in }
        #expect(store.commitShortcutConfiguration(next))
        let referenced = try #require(store.reviewSavedItemRemoval(.applicationAction(f.action.id)))
        #expect(referenced.dependencies.count == 1 && !store.removeSavedItem(referenced))
        next = store.configuration; next.collections = []; #expect(store.commitSettingsConfiguration(next))
        let review = try #require(store.reviewSavedItemRemoval(.applicationAction(f.action.id)))
        let raw = try Data(contentsOf: f.configuration)
        f.relay.failure = .after
        #expect(!store.removeSavedItem(review)); #expect(try Data(contentsOf: f.configuration) == raw)
        #expect(store.applicationActions == [f.action] && store.configuration.commandShortcuts[id] != nil)
        #expect(store.removeSavedItem(review))
        #expect(store.applicationActions.isEmpty && store.configuration.commandShortcuts[id] == nil)
        #expect(!store.configuration.preferences.favorites.contains(id) && store.configuration.preferences.aliases[id] == nil && store.configuration.preferences.recent[id] == nil)
        #expect(store.configuration.commandShortcuts[neighbor] != nil && store.configuration.preferences.favorites.contains(neighbor) && store.configuration.preferences.aliases[neighbor] == "keep" && store.configuration.preferences.recent[neighbor] != nil)
        await f.cleanup(store)
    }
    @Test func staleEditorAndRemovalCannotApplyAfterEditUndoOrDelete() async throws {
        let f = try ApplicationConfigurationFixture(), store = try f.model()
        #expect(store.saveApplicationAction(f.action))
        let revision = try #require(store.applicationActionRevision(f.action))
        let review = try #require(store.reviewSavedItemRemoval(.applicationAction(f.action.id)))
        let changed = try SavedApplicationAction(id: f.action.id, name: "Changed synthetic", applicationID: f.action.applicationID, behavior: .show)
        #expect(store.saveApplicationAction(changed, expectedRevision: revision))
        #expect(store.saveApplicationAction(f.action))
        #expect(!store.removeSavedItem(review) && !store.saveApplicationAction(changed, expectedRevision: revision))
        let finalRevision = try #require(store.applicationActionRevision(f.action))
        #expect(store.deleteApplicationAction(f.action.id))
        #expect(!store.saveApplicationAction(changed, expectedRevision: finalRevision))
        #expect(store.applicationActions.isEmpty)
        #expect(store.saveApplicationAction(changed, creating: true))
        #expect(!store.saveApplicationAction(changed, creating: true))
        await f.cleanup(store)
    }
    @Test(arguments: [false, true]) func reboundDirectoryRefusesAllConfigurationPortsWithoutOverwritingNeighbor(_ unknownSource: Bool) async throws {
        let f = try ApplicationConfigurationFixture()
        if unknownSource { try Data("unknown".utf8).write(to: f.legacy) }
        let store = try f.model(), moved = f.directory.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: f.directory, to: moved)
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sentinel = Data("neighbor-configuration-preserved".utf8); try sentinel.write(to: f.configuration)
        #expect(!store.setLanguage("en") && !store.setLauncherShortcut(nil))
        #expect(!store.saveAPIConfiguration(endpoint: "https://example.com/v1/chat/completions", modelName: "synthetic", localHTTP: false, tokenParameter: "max_completion_tokens", apiKey: ""))
        #expect(try Data(contentsOf: f.configuration) == sentinel)
        await f.cleanup(store); try FileManager.default.removeItem(at: moved)
    }
    @Test func apiSaveMigratesWithoutReadingOrWritingACredentialWhenKeyIsBlank() async throws {
        let f = try ApplicationConfigurationFixture(), store = try f.model()
        #expect(store.saveAPIConfiguration(endpoint: "https://example.com/v1/chat/completions", modelName: "synthetic", localHTTP: false, tokenParameter: "max_completion_tokens", apiKey: ""))
        #expect(store.configuration.savedApplicationActions == [f.action] && store.configuration.endpoint == "https://example.com/v1/chat/completions")
        await f.cleanup(store)
    }
    @Test func directoryReboundInsideCompensationCannotBeReportedAsRestored() async throws {
        let f = try ApplicationConfigurationFixture(); try f.oldConfiguration(2)
        let original = try Data(contentsOf: f.configuration), store = try f.model()
        let moved = f.directory.appendingPathExtension("retained")
        // 第一次writer替换后抛错；补偿writer返回前把同字节邻居放到原路径。
        f.relay.failure = .after
        f.writerHook = { [f] in
            f.writerHook = nil
            try FileManager.default.moveItem(at: f.directory, to: moved)
            try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try original.write(to: f.configuration)
        }
        #expect(!store.setLanguage("en"))
        #expect(store.settingsNoticeMessage == noticeKey("Settings could not be saved and the previous file could not be restored. Check settings before restarting."))
        #expect(try Data(contentsOf: f.configuration) == original)
        await f.cleanup(store); try FileManager.default.removeItem(at: moved)
    }
    @Test func canonicalNullAndEmptyRemainDistinctAndDisabledLauncherSurvivesReload() throws {
        let variants: [[SavedApplicationAction]?] = [nil, []]
        for actions in variants {
            var c = AppConfiguration(); c.savedApplicationActions = actions; c.launcherShortcut = nil
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
            #expect(decoded.savedApplicationActions == actions && decoded.launcherShortcut == nil)
            var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            document.removeValue(forKey: "savedApplicationActions")
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: document)) }
            document["schemaVersion"] = 2; document["savedApplicationActions"] = NSNull()
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: document)) }
        }
    }
    @Test func editorOwnershipSurvivesPaneChangesAndFreezesIdentityUntilActualDismissal() async throws {
        let f = try ApplicationConfigurationFixture(), store = try f.model()
        #expect(store.saveApplicationAction(f.action))
        let session = SettingsSession(store: store)
        session.beginApplicationAction(f.action, in: store)
        let original = try #require(session.applicationActionEditor)
        session.applicationActionEditorDidAppear(original.id)
        original.name = "Unsaved draft text"
        let changed = try SavedApplicationAction(id: f.action.id, name: "Changed", applicationID: f.action.applicationID, behavior: .show)
        #expect(store.saveApplicationAction(changed) && store.saveApplicationAction(f.action))
        session.pane = .general
        #expect(session.applicationActionEditor?.id == original.id && session.applicationActionEditor?.expectedRevision == original.expectedRevision)
        #expect(session.applicationActionEditor?.name == "Unsaved draft text")
        #expect(!store.saveApplicationAction(changed, expectedRevision: original.expectedRevision))
        session.prepareRemoval(.applicationAction(f.action.id), in: store)
        session.beginApplicationAction(nil, in: store)
        #expect(session.savedItemRemoval == nil && session.applicationActionEditor?.id == original.id)
        session.closeApplicationActionEditor(original.id)
        #expect(!session.canBeginSavedItemEditor)
        session.beginApplicationAction(nil, in: store); #expect(session.applicationActionEditor?.id == original.id)
        session.applicationActionEditorDidDismiss(original.id)
        session.beginApplicationAction(nil, in: store)
        let creation = try #require(session.applicationActionEditor)
        session.applicationActionEditorDidAppear(creation.id)
        #expect(creation.initial == nil && creation.actionID == creation.id && creation.actionID != original.actionID)
        session.closeApplicationActionEditor(original.id)
        session.applicationActionEditorDidDismiss(original.id)
        #expect(session.applicationActionEditor?.id == creation.id && !session.canBeginSavedItemEditor)
        session.closeApplicationActionEditor(creation.id)
        session.applicationActionEditorDidDismiss(original.id)
        #expect(session.applicationActionEditor?.id == creation.id && !session.canBeginSavedItemEditor)
        session.applicationActionEditorDidDismiss(creation.id)
        #expect(session.canBeginSavedItemEditor)
        await f.cleanup(store)
    }
}
