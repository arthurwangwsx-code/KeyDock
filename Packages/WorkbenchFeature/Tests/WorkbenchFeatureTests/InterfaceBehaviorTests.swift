import Foundation
import Testing
import CommandCore
import ExecutionCore
import MacAdapters
import KeyDockUI
@testable import WorkbenchFeature

@MainActor final class InterfaceWriteRelay {
    enum Failure: Sendable { case before, after }
    var failure: Failure?
    func write(_ bytes: Data, to url: URL) throws {
        let failure = self.failure; self.failure = nil
        if failure == .before { throw CocoaError(.fileWriteUnknown) }
        try PrivateFiles.write(bytes, to: url)
        if failure == .after { throw CocoaError(.fileWriteUnknown) }
    }
}

/// 真实设置提交与窗口会话，只使用合成目录；不接触 AX、系统剪贴板或钥匙串。
@Suite(.serialized) @MainActor struct InterfaceBehaviorTests {
    private func withStore(_ body: (WorkbenchModel, InterfaceWriteRelay, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Interface-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let languageKey = (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) ? "KeyDock.Smoke.Language" : "KeyDock.Language"
        let oldLanguage = UserDefaults.standard.object(forKey: languageKey)
        let oldPane = UserDefaults.standard.object(forKey: "KeyDock.Smoke.SettingsPane")
        let relay = InterfaceWriteRelay()
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            configurationWriter: relay.write, applicationCatalog: ApplicationCatalog(roots: []))
        defer {
            store.shutdown()
            if let oldLanguage { UserDefaults.standard.set(oldLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
            if let oldPane { UserDefaults.standard.set(oldPane, forKey: "KeyDock.Smoke.SettingsPane") }
            else { UserDefaults.standard.removeObject(forKey: "KeyDock.Smoke.SettingsPane") }
            try? FileManager.default.removeItem(at: directory)
        }
        try body(store, relay, directory)
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after], [false, true])
    func rejectedAppearanceAndLanguageKeepUIAndExactFile(failure: InterfaceWriteRelay.Failure, hasFile: Bool) throws {
        try withStore { store, relay, directory in
            let file = directory.appendingPathComponent("configuration.json")
            var original = try JSONEncoder().encode(store.configuration); original.append(0x0A)
            if hasFile { try original.write(to: file) }
            let language = store.configuration.language, appearance = store.configuration.appearance
            let renderedLanguage = KDLocalizer.language
            var languageChanges = 0, appearanceChanges = 0
            store.onLanguageChanged = { languageChanges += 1 }; store.onAppearanceChanged = { appearanceChanges += 1 }
            relay.failure = failure
            #expect(!store.setLanguage("zh-Hans"))
            #expect(store.configuration.language == language && KDLocalizer.language == renderedLanguage)
            #expect(languageChanges == 0)
            relay.failure = failure
            #expect(!store.setAppearance("dark"))
            #expect(store.configuration.appearance == appearance && appearanceChanges == 0)
            if hasFile { #expect(try Data(contentsOf: file) == original) }
            else { #expect(!FileManager.default.fileExists(atPath: file.path)) }
            #expect(!store.settingsNotice.isEmpty)
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func failedCommandEditPreservesSavedCommandAndCatalog(failure: InterfaceWriteRelay.Failure) throws {
        try withStore { store, relay, directory in
            let command = SavedCommand(name: "Synthetic original", executable: "/usr/bin/printf", workingDirectory: directory.path)
            #expect(store.saveCommand(command))
            let file = directory.appendingPathComponent("configuration.json"), original = try Data(contentsOf: directory.appendingPathComponent("configuration.json"))
            var edited = command; edited.name = "Synthetic unsaved"
            relay.failure = failure
            #expect(!store.saveCommand(edited))
            #expect(store.configuration.savedCommands == [command])
            #expect(store.catalog.contains { $0.title == command.name })
            #expect(!store.catalog.contains { $0.title == edited.name })
            #expect(try Data(contentsOf: file) == original)
            #expect(store.saveCommand(edited))
            #expect(try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: file)).savedCommands == [edited])
        }
    }

    @Test func successfulPreferencesPublishAfterPersistenceAndRejectUnknownValues() throws {
        try withStore { store, _, directory in
            var changed = 0; store.onLanguageChanged = { changed += 1 }
            #expect(store.setLanguage("zh-Hans")); #expect(changed == 1)
            #expect(KDLocalizer.resolvedLanguage == "zh-Hans")
            #expect(store.setAppearance("dark"))
            #expect(!store.setLanguage("unknown") && !store.setAppearance("unknown"))
            let saved = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("configuration.json")))
            #expect(saved.language == "zh-Hans" && saved.appearance == "dark")
        }
    }

    @Test func shortcutDeepLinkKeepsExactUnfavoritedApplicationAndUserCanSearchAgain() throws {
        try withStore { store, _, _ in
            let first = CommandItem(id: "synthetic.first", title: "Same app", kind: .application, payload: "/synthetic/first.app")
            let second = CommandItem(id: "synthetic.second", title: "Same app", kind: .application, payload: "/synthetic/second.app")
            let session = SettingsSession(store: store)
            session.focusShortcut(second)
            #expect(session.pane == .shortcuts)
            #expect(session.shortcutItems(in: [first, second], preferences: .init()).map(\.id) == [second.id])
            session.editShortcutQuery("Same")
            #expect(session.shortcutTargetID == nil)
            #expect(session.shortcutItems(in: [first, second], preferences: .init()).count == 2)
        }
    }

    @Test func newAIDraftPreservesPreviousDocumentAndOtherWindowSession() throws {
        try withStore { store, _, _ in
            let workspace = WorkspaceSession(), launcher = LauncherSession(store: store)
            workspace.createDraft(in: store)
            let previous = try #require(workspace.draft); previous.editInput("Synthetic unsaved input")
            launcher.draft = previous; workspace.createDraft(in: store)
            #expect(workspace.page == .ai && workspace.draft?.id != previous.id)
            #expect(store.ownsDraft(previous) && previous.input == "Synthetic unsaved input")
            #expect(launcher.draft === previous)
            let recoverable = try #require(workspace.availableDrafts(in: store).first { $0.id == previous.id })
            workspace.navigate(.ai(recoverable.id), store: store)
            #expect(workspace.draft === previous && workspace.draft?.input == "Synthetic unsaved input")
        }
    }

    @Test func languageResolverUsesOnlySupportedLocalizations() {
        #expect(KDLocalizer.resolveLanguage(preference: "en", preferredLanguages: ["zh-Hans-CN"]) == "en")
        #expect(KDLocalizer.resolveLanguage(preference: "zh-Hans", preferredLanguages: ["en-GB"]) == "zh-Hans")
        #expect(KDLocalizer.resolveLanguage(preference: "system", preferredLanguages: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(KDLocalizer.resolveLanguage(preference: "system", preferredLanguages: ["en-GB"]) == "en")
        #expect(KDLocalizer.resolveLanguage(preference: "invalid", preferredLanguages: ["fr-FR"]) == "en")
    }

    @Test func existingAppNoticesChangeLanguageWhileUserAndModelContentRemainVerbatim() throws {
        try withStore { store, _, _ in
            #expect(store.setLanguage("en"))
            let action = try #require(store.configuration.aiActions.first)
            let draft = store.createDraft(actionID: action.id, input: "Synthetic user text")
            #expect(store.runAI(action: action, draft: draft) == nil) // 未配置 API；不会发起请求。
            let oldError = draft.notice
            #expect(!oldError.isEmpty)
            store.workspaceNoticeMessage = noticeKey("Clipboard storage failed")
            store.reportShortcutRegistrationFailure()
            let oldShortcutError = store.launcherNotice
            var task = RunningTaskItem(id: UUID(), title: "Synthetic task", state: .completed, output: "No output")
            task.noticeMessage = noticeKey("AI draft only. Review command, directory and effects before saving or running.", suffix: "Synthetic model explanation")
            let previousTaskNotice = task.notice
            #expect(store.setLanguage("zh-Hans"))
            #expect(draft.notice != oldError && draft.notice == L("Configure a valid API endpoint and model in Settings"))
            #expect(store.workspaceNotice == L("Clipboard storage failed"))
            #expect(store.launcherNotice != oldShortcutError && store.shortcutsUnavailable)
            #expect(task.notice != previousTaskNotice && task.notice.hasSuffix("Synthetic model explanation"))
            #expect(task.output == "No output" && draft.input == "Synthetic user text")
            task.notice = "No output"
            #expect(task.notice == "No output") // 原文恰好等于一个 key，也不能自动翻译。
        }
    }

    @Test func noticeStorageAndRenderingStayBoundedWithoutTruncatingLocalizationKeys() throws {
        try withStore { store, _, _ in
            let draft = store.createDraft(input: "Synthetic")
            let large = String(repeating: "中文🙂", count: 5_000)
            draft.noticeMessage = noticeKey("No output", suffix: large)
            #expect(draft.noticeMessage.retainedByteCount <= 8_192)
            #expect(draft.notice.utf8.count <= 8_192)
            var task = RunningTaskItem(id: UUID(), title: "Synthetic", state: .failed)
            task.noticeMessage = .verbatim(large).appending(noticeKey("No output"))
            #expect(task.noticeMessage.retainedByteCount <= 8_192 && task.notice.utf8.count <= 8_192)
            #expect(LocalizedNotice.key(large, suffix: nil).bounded(maximumBytes: 10) == .none)
        }
    }
}
