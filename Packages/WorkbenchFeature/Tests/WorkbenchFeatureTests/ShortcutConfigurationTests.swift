import Foundation
import Testing
import CommandCore
import MacAdapters
import KeyDockUI
import ExecutionCore
@testable import WorkbenchFeature

@MainActor private final class ShortcutTransactionRegistry: HotkeyRegistering {
    var bindings: [UInt32: HotkeyBinding] = [:]
    var blocked: Set<HotkeyBinding> = []
    func install(receiver: @escaping @Sendable (HotkeyEvent) -> Void) throws {}
    func register(id: UInt32, binding: HotkeyBinding) throws {
        guard !blocked.contains(binding) else { throw HotkeyRegistrationError(status: -9878) }
        bindings[id] = binding
    }
    func unregister(id: UInt32) { bindings[id] = nil }
    func shutdown() { bindings = [:] }
}

@MainActor private final class ShortcutTransactionFixture {
    let directory: URL
    let store: WorkbenchModel
    let registry: ShortcutTransactionRegistry
    let center: HotkeyCenter
    var writes = 0
    var beforeWrite: (() throws -> Void)?
    var afterWrite: (() throws -> Void)?
    private let languageKey: String
    private let previousLanguage: Any?
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Shortcut-Synthetic-" + UUID().uuidString)
        registry = ShortcutTransactionRegistry(); center = HotkeyCenter(registry: registry)
        languageKey = (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) ? "KeyDock.Smoke.Language" : "KeyDock.Language"
        previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // writer 使用转发容器，避免初始化 self 时捕获尚未完成的 fixture。
        let relay = ConfigurationWriterRelay()
        store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            configurationWriter: { data, url in try relay.write(data, url) }, applicationCatalog: ApplicationCatalog(roots: []))
        relay.write = { [weak self] data, url in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            self.writes += 1; try self.beforeWrite?(); try PrivateFiles.write(data, to: url); try self.afterWrite?()
        }
        let center = self.center
        store.onShortcutConfigurationChanged = { [weak store] configuration in
            guard let store else { throw HotkeyRegistrationError(status: -50) }
            let entries = ShortcutPlan.entries(configuration)
            do {
                try center.replace(entries.map { .init(id: $0.id, binding: $0.binding) {} })
                store.shortcutsUnavailable = false
            } catch {
                if entries == ShortcutPlan.entries(store.configuration) { center.invalidate() }
                store.shortcutsUnavailable = center.isUnavailable
                throw error
            }
        }
        try center.replace(ShortcutPlan.entries(store.configuration).map { .init(id: $0.id, binding: $0.binding) {} })
    }
    func cleanup() async {
        beforeWrite = nil; afterWrite = nil
        store.onShortcutConfigurationChanged = nil
        center.shutdown(); await store.shutdownAndWait()
        if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: languageKey) }
        else { UserDefaults.standard.removeObject(forKey: languageKey) }
        try? FileManager.default.removeItem(at: directory)
    }
}
@MainActor private final class ConfigurationWriterRelay {
    var write: (Data, URL) throws -> Void = { _, _ in throw CocoaError(.fileWriteUnknown) }
}

/// 真实 Store + 合成注册表：不读按键、不注册 OS、不操作窗口。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ShortcutConfigurationTests {
    private let next = HotkeyBinding(keyCode: 2)
    private func withFixture(_ body: (ShortcutTransactionFixture) async throws -> Void) async throws {
        let fixture = try ShortcutTransactionFixture()
        do { try await body(fixture); await fixture.cleanup() }
        catch { await fixture.cleanup(); throw error }
    }

    @Test func contributionSwitchPublishesEpochOnlyAfterOSAndStorageCommitAndKeepsShortcutPreferences() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let command = SavedCommand(name:"Synthetic contribution shortcut",executable:"/usr/bin/printf",arguments:["synthetic"],workingDirectory:fixture.directory.path)
            store.configuration.savedCommands = [command]; store.rebuildCatalog()
            let id = "command."+command.id.uuidString
            #expect(store.setShortcut(next,for:id))
            let epoch = store.contributionEpoch, before = try Data(contentsOf:fixture.directory.appendingPathComponent("configuration.json"))
            let pending = try #require(store.prepareShortcutInvocation(id:id))
            fixture.afterWrite = { throw CocoaError(.fileWriteUnknown) }
            #expect(!store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            #expect(store.contributionEpoch == epoch && store.isContributionEnabled(BuiltinContributionID.commands))
            #expect(try Data(contentsOf:fixture.directory.appendingPathComponent("configuration.json")) == before)
            #expect(fixture.registry.bindings.values.contains(next))
            fixture.afterWrite = nil
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            #expect(store.contributionEpoch != epoch && store.configuration.commandShortcuts[id] == next)
            #expect(!fixture.registry.bindings.values.contains(next))
            #expect(store.setContributionEnabled(true,id:BuiltinContributionID.commands))
            #expect(fixture.registry.bindings.values.contains(next))
            store.performCommand(pending)
            #expect(store.tasks.isEmpty && store.executionReservations.isEmpty)
        }
    }

    @Test func failedContributionEnableRegistrationKeepsDisabledEpochAndBytes() async throws {
        try await withFixture { fixture in
            let store = fixture.store, id = "command."+UUID().uuidString
            #expect(store.setShortcut(next,for:id))
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.commands))
            let epoch = store.contributionEpoch, writes = fixture.writes
            let bytes = try Data(contentsOf:fixture.directory.appendingPathComponent("configuration.json"))
            fixture.registry.blocked = [next]
            #expect(!store.setContributionEnabled(true,id:BuiltinContributionID.commands))
            #expect(store.contributionEpoch == epoch && !store.isContributionEnabled(BuiltinContributionID.commands))
            #expect(fixture.writes == writes && !fixture.registry.bindings.values.contains(next))
            #expect(try Data(contentsOf:fixture.directory.appendingPathComponent("configuration.json")) == bytes)
        }
    }

    @Test func registrationFailureNeverWritesOrPublishesTheCandidate() async throws {
        try await withFixture { fixture in
            let old = fixture.store.configuration.launcherShortcut
            fixture.registry.blocked = [next]
            #expect(!fixture.store.setLauncherShortcut(next))
            #expect(fixture.store.configuration.launcherShortcut == old && fixture.writes == 0)
            #expect(Set(fixture.registry.bindings.values) == Set(old.map { [$0] } ?? []))
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("configuration.json").path))
        }
    }

    @Test func storageFailureRestoresTheOldOSPlanAndKeepsTheActionDraft() async throws {
        try await withFixture { fixture in
            let old = fixture.store.configuration.launcherShortcut
            fixture.beforeWrite = { throw CocoaError(.fileWriteOutOfSpace) }
            #expect(!fixture.store.setLauncherShortcut(next))
            #expect(fixture.store.configuration.launcherShortcut == old && !fixture.store.shortcutsUnavailable)
            #expect(Set(fixture.registry.bindings.values) == Set(old.map { [$0] } ?? []))
            var draft = AIActionPreset(name: "Synthetic uncommitted draft", prompt: "Synthetic prompt")
            draft.shortcut = next
            let count = fixture.store.configuration.aiActions.count
            #expect(!fixture.store.saveAction(draft))
            #expect(fixture.store.configuration.aiActions.count == count)
            #expect(!fixture.store.configuration.aiActions.contains { $0.id == draft.id })
        }
    }

    @Test func failedStorageAndFailedOSRestorationDisableCandidateUntilRetry() async throws {
        try await withFixture { fixture in
            let old = try #require(fixture.store.configuration.launcherShortcut)
            fixture.beforeWrite = {
                fixture.registry.blocked = [old]
                throw CocoaError(.fileWriteOutOfSpace)
            }
            #expect(!fixture.store.setLauncherShortcut(next))
            #expect(fixture.store.configuration.launcherShortcut == old && fixture.store.shortcutsUnavailable)
            #expect(fixture.center.activeIDs.isEmpty && fixture.registry.bindings.isEmpty)
            #expect(fixture.store.settingsNotice == L("Shortcut changes could not be saved and rollback was incomplete. Check the saved shortcuts before retrying."))
            fixture.registry.blocked = []; fixture.beforeWrite = nil
            fixture.store.retryShortcuts()
            #expect(!fixture.store.shortcutsUnavailable && Set(fixture.registry.bindings.values) == [old])
            #expect(fixture.store.configuration.launcherShortcut == old)
        }
    }

    @Test func postWriteThrowRestoresRawBytesOrAbsentFileAndOldOSBindings() async throws {
        for existingFile in [true, false] {
            try await withFixture { fixture in
                let old = fixture.store.configuration.launcherShortcut
                let url = fixture.directory.appendingPathComponent("configuration.json")
                let original = Data(" \n".utf8) + (try JSONEncoder().encode(fixture.store.configuration)) + Data("\n".utf8)
                if existingFile { try PrivateFiles.write(original, to: url) }
                fixture.afterWrite = { if fixture.writes == 1 { throw CocoaError(.fileWriteUnknown) } }
                #expect(!fixture.store.setLauncherShortcut(next))
                #expect(fixture.store.configuration.launcherShortcut == old)
                #expect(Set(fixture.registry.bindings.values) == Set(old.map { [$0] } ?? []))
                if existingFile { #expect(try Data(contentsOf: url) == original && fixture.writes == 2) }
                else { #expect(!FileManager.default.fileExists(atPath: url.path) && fixture.writes == 1) }
                #expect(fixture.store.settingsNotice == L("Shortcut changes could not be saved. Previous settings were kept."))
            }
        }
    }

    @Test func fileCompensationFailureIsExplicitAndStillRestoresTheOSPlan() async throws {
        try await withFixture { fixture in
            let old = fixture.store.configuration.launcherShortcut
            let url = fixture.directory.appendingPathComponent("configuration.json")
            let original = Data(" \n".utf8) + (try JSONEncoder().encode(fixture.store.configuration)) + Data("\n".utf8)
            try PrivateFiles.write(original, to: url)
            fixture.beforeWrite = { if fixture.writes == 2 { throw CocoaError(.fileWriteOutOfSpace) } }
            fixture.afterWrite = { if fixture.writes == 1 { throw CocoaError(.fileWriteUnknown) } }
            #expect(!fixture.store.setLauncherShortcut(next))
            #expect(fixture.writes == 2 && fixture.store.configuration.launcherShortcut == old)
            #expect(Set(fixture.registry.bindings.values) == Set(old.map { [$0] } ?? []))
            let persisted = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
            #expect(persisted.launcherShortcut == next)
            #expect(fixture.store.settingsNotice == L("Shortcut changes could not be saved and rollback was incomplete. Check the saved shortcuts before retrying."))
        }
    }

    @Test func workspaceBindingPostWriteFailureRestoresBytesRegistrationAndDefinition() async throws {
        try await withFixture { fixture in
            let store = fixture.store, appID = "app./Applications/SyntheticWorkspace.app"
            store.desktop.applicationCatalog.onChange?([CommandItem(id: appID, title: "Synthetic", kind: .application, payload: "/Applications/SyntheticWorkspace.app")])
            let workspace = try SavedDesktopWorkspace(name: "Synthetic workspace", entries: [.init(applicationID: appID)])
            #expect(store.saveDesktopWorkspace(workspace, expectedRevision: nil))
            #expect(store.setShortcut(next, for: workspace.commandID))
            let file = fixture.directory.appendingPathComponent("configuration.json"), bytes = try Data(contentsOf: file), plan = Set(fixture.registry.bindings.values), baselineWrites = fixture.writes
            fixture.afterWrite = { if fixture.writes == baselineWrites+1 { throw CocoaError(.fileWriteUnknown) } }
            let accepted = store.setShortcut(HotkeyBinding(keyCode: 3), for: workspace.commandID)
            #expect(!accepted)
            #expect(store.shortcut(for: workspace.commandID) == next && Set(fixture.registry.bindings.values) == plan)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(store.desktopWorkspaces == [workspace] && !store.removeDesktopWorkspace(workspace))
            fixture.afterWrite = nil
            #expect(store.setShortcut(nil, for: workspace.commandID) && store.removeDesktopWorkspace(workspace))
        }
    }

    @Test(arguments: [false,true]) func failedWorkspaceAliasClearPreservesMemoryBytesAndDeletionGuard(afterWrite: Bool) async throws {
        try await withFixture { fixture in
            let store = fixture.store, appID = "app./Applications/SyntheticWorkspace.app"
            store.desktop.applicationCatalog.onChange?([CommandItem(id: appID, title: "Synthetic", kind: .application, payload: "/Applications/SyntheticWorkspace.app")])
            let workspace = try SavedDesktopWorkspace(name: "Synthetic workspace", entries: [.init(applicationID: appID)])
            #expect(store.saveDesktopWorkspace(workspace, expectedRevision: nil))
            let saved = store.setAlias("synthetic-desk", for: workspace.commandID); #expect(saved)
            let file = fixture.directory.appendingPathComponent("configuration.json"), bytes = try Data(contentsOf: file), baseline = fixture.writes
            let fail: () throws -> Void = { if fixture.writes == baseline+1 { throw CocoaError(.fileWriteUnknown) } }
            if afterWrite { fixture.afterWrite = fail } else { fixture.beforeWrite = fail }
            let cleared = store.setAlias("", for: workspace.commandID)
            #expect(!cleared && store.configuration.preferences.aliases[workspace.commandID] == "synthetic-desk")
            #expect(try Data(contentsOf: file) == bytes)
            #expect(!store.removeDesktopWorkspace(workspace))
            fixture.beforeWrite = nil; fixture.afterWrite = nil
            let retried = store.setAlias("  ", for: workspace.commandID)
            #expect(retried && store.configuration.preferences.aliases[workspace.commandID] == nil)
            #expect(store.removeDesktopWorkspace(workspace))
        }
    }

    @Test func acceptedShortcutIsWrittenExactlyOnceAndMatchesTheActivePlan() async throws {
        try await withFixture { fixture in
            #expect(fixture.store.setLauncherShortcut(next))
            let data = try Data(contentsOf: fixture.directory.appendingPathComponent("configuration.json"))
            let saved = try JSONDecoder().decode(AppConfiguration.self, from: data)
            #expect(fixture.writes == 1 && saved.launcherShortcut == next)
            #expect(fixture.store.configuration.launcherShortcut == next && Set(fixture.registry.bindings.values) == [next])
        }
    }
}
