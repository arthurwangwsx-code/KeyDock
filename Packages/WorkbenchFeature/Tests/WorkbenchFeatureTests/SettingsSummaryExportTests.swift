import Foundation
import Testing
import CommandCore
import ExecutionCore
import AgentCore
import AutomationCore
import MCPAdapters
import MacAdapters
@testable import WorkbenchFeature

struct SettingsSummaryProjectionTests {
    private let clipboard = ClipboardSummaryPreferences(primaryAction: .copy, separator: .blankLine)
    private func object(_ snapshot: FrozenSettingsSummary) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any])
    }
    @Test func privateContentAcrossEveryConfigurationContainerCannotEnterTheSummary() throws {
        let sentinel = "SensitiveSummary-" + UUID().uuidString
        var configuration = AppConfiguration()
        configuration.schemaVersion = 978; configuration.endpoint = "https://example.com/" + sentinel
        configuration.model = sentinel; configuration.tokenLimitParameter = sentinel
        configuration.language = sentinel; configuration.appearance = sentinel; configuration.clipboardExclusions = [sentinel]
        configuration.preferences.aliases[sentinel] = sentinel; configuration.preferences.favorites = [sentinel]
        configuration.preferences.recent[sentinel] = Date(timeIntervalSince1970: 123)
        configuration.commandShortcuts[sentinel] = HotkeyBinding(); configuration.disabledContributions = [sentinel]
        configuration.savedCommands = [.init(name: sentinel, executable: "/" + sentinel, arguments: [sentinel], workingDirectory: "/" + sentinel, environment: [sentinel: sentinel])]
        var action = AIActionPreset(name: sentinel, prompt: sentinel, builtinKey: sentinel); action.modelOverride = sentinel
        configuration.aiActions = [action]
        var agent = AgentDefinition(); agent.name = sentinel; agent.instructions = sentinel; agent.modelOverride = sentinel; agent.allowedMCPToolNames = [sentinel]
        configuration.agents = [agent]
        configuration.workflows = [.init(name: sentinel, steps: [.init(operation: .transform(.trim), input: .literal(sentinel))])]
        configuration.snippets = [try .init(name: sentinel, text: sentinel)]
        configuration.webActions = [try .init(name: sentinel, urlTemplate: "https://example.com/" + sentinel + "?secret=" + sentinel)]
        configuration.collections = [try .init(name: sentinel, commandIDs: ["utility." + sentinel])]
        configuration.savedApplicationActions = [try .init(name: sentinel, applicationID: "app./" + sentinel + ".app", behavior: .hide)]
        configuration.searchFolders = [.init(id: UUID(), name: sentinel, bookmark: Data(sentinel.utf8))]
        configuration.mcpServers = [.init(name: sentinel, endpoint: try #require(URL(string: "https://example.com/" + sentinel)), secretReference: sentinel)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // 摘要仍须过滤未知schema号；主配置writer则只编码当前schema。
        func comparable() throws -> Data { var copy = configuration; copy.schemaVersion = 3; return try encoder.encode(copy) }
        let original = try comparable()
        let snapshot = try SettingsSummaryProjection.make(configuration: configuration, clipboard: clipboard, sections: Set(SettingsSummarySection.allCases))
        #expect(!snapshot.preview.contains(sentinel) && !snapshot.preview.contains(Data(sentinel.utf8).base64EncodedString()))
        #expect(!snapshot.preview.contains(action.id.uuidString) && !snapshot.preview.contains(agent.id.uuidString))
        #expect(try comparable() == original)
        #expect(configuration.schemaVersion == 978)
        let json = try object(snapshot)
        #expect(Set(json.keys) == ["format", "schemaVersion", "basicPreferences", "launcherShortcut", "configurationCounts"])
        #expect(json["format"] as? String == "KeyDock.settings-summary" && json["schemaVersion"] as? Int == 1)
        let basic = try #require(json["basicPreferences"] as? [String: Any])
        #expect(Set(basic.keys) == ["language", "appearance", "clipboardRecordingEnabled", "activityRecordingEnabled", "clipboardPrimaryAction", "clipboardSeparator"])
        #expect(basic["language"] as? String == "unknown" && basic["appearance"] as? String == "unknown")
        let counts = try #require(json["configurationCounts"] as? [String: Int])
        #expect(Set(counts.keys) == ["savedCommands", "aiActions", "agents", "workflows", "snippets", "webActions", "collections", "searchFolders", "mcpServers", "aliases", "favorites"])
        #expect(counts.values.allSatisfy { $0 == 1 })
        let shortcut = try #require(json["launcherShortcut"] as? [String: Any])
        #expect(Set(shortcut.keys) == ["state", "keyCode", "modifiers"])
    }
    @Test(arguments: 1...7) func optionalSectionsAreAnExactAllowlist(mask: Int) throws {
        let all = SettingsSummarySection.allCases
        let selected = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
        let snapshot = try SettingsSummaryProjection.make(configuration: .init(), clipboard: clipboard, sections: selected)
        let json = try object(snapshot)
        #expect(Set(json.keys) == Set(["format", "schemaVersion"] + selected.map(\.rawValue)))
        #expect(snapshot.sections == selected && snapshot.data.count < SettingsSummaryProjection.maximumBytes)
    }
    @Test func knownPreferencesArePreservedAndUnknownStringsNeverEscape() throws {
        var configuration = AppConfiguration(); configuration.language = "zh-Hans"; configuration.appearance = "dark"
        configuration.clipboardEnabled = true; configuration.activityEnabled = true
        let snapshot = try SettingsSummaryProjection.make(configuration: configuration, clipboard: clipboard, sections: [.basicPreferences])
        let basic = try #require(try object(snapshot)["basicPreferences"] as? [String: Any])
        #expect(basic["language"] as? String == "zh-Hans" && basic["appearance"] as? String == "dark")
        #expect(basic["clipboardRecordingEnabled"] as? Bool == true && basic["activityRecordingEnabled"] as? Bool == true)
        #expect(basic["clipboardPrimaryAction"] as? String == "copy" && basic["clipboardSeparator"] as? String == "blankLine")
    }
    @Test func disabledAndInvalidHotkeysExportOnlyTheirFixedState() throws {
        let bindings: [HotkeyBinding?] = [nil, HotkeyBinding(keyCode: 128), HotkeyBinding(modifiers: UInt32.max), HotkeyBinding(modifiers: 0)]
        for binding in bindings {
            var configuration = AppConfiguration(); configuration.launcherShortcut = binding
            let snapshot = try SettingsSummaryProjection.make(configuration: configuration, clipboard: clipboard, sections: [.launcherShortcut])
            let shortcut = try #require(try object(snapshot)["launcherShortcut"] as? [String: String])
            #expect(shortcut == ["state": binding == nil ? "disabled" : "invalid"])
        }
    }
    @Test func emptySelectionAndOversizeAreRejectedWithoutTruncation() throws {
        #expect(throws: SettingsSummaryError.noSections) { try SettingsSummaryProjection.make(configuration: .init(), clipboard: clipboard, sections: []) }
        let snapshot = try SettingsSummaryProjection.make(configuration: .init(), clipboard: clipboard, sections: [.basicPreferences])
        let exact = try SettingsSummaryProjection.make(configuration: .init(), clipboard: clipboard, sections: [.basicPreferences], maximumBytes: snapshot.data.count)
        #expect(exact.data == snapshot.data)
        #expect(throws: SettingsSummaryError.tooLarge) { try SettingsSummaryProjection.make(configuration: .init(), clipboard: clipboard, sections: [.basicPreferences], maximumBytes: snapshot.data.count - 1) }
    }
    @Test func recentHistoryAndItsSizeCannotAffectAnySummaryBytes() throws {
        var configuration = AppConfiguration()
        let before = try SettingsSummaryProjection.make(configuration: configuration, clipboard: clipboard, sections: Set(SettingsSummarySection.allCases))
        for index in 0..<100 { configuration.preferences.recent["Sensitive history \(index)"] = Date(timeIntervalSince1970: Double(index)) }
        let after = try SettingsSummaryProjection.make(configuration: configuration, clipboard: clipboard, sections: Set(SettingsSummarySection.allCases))
        #expect(after.data == before.data)
    }
}

@Suite(.serialized) @MainActor struct SettingsSummarySessionTests {
    private func withFixture(_ body: (SavedToolFixture) async throws -> Void) async throws {
        let fixture = try SavedToolFixture()
        do { try await body(fixture); await fixture.cleanup() } catch { await fixture.cleanup(); throw error }
    }
    @Test func prepareAndSaveTicketsDoNotMutateConfigurationOrTouchHostPorts() async throws {
        try await withFixture { fixture in
            _ = try fixture.add(.snippet)
            let before = try Data(contentsOf: fixture.file), calls = fixture.registrationCalls
            let session = SettingsSession(store: fixture.store); session.prepareSettingsSummary(in: fixture.store)
            let presentation = try #require(session.settingsSummaryExport), snapshot = try #require(presentation.snapshot)
            #expect(presentation.sections == [.basicPreferences] && presentation.canSave)
            let attempt = try #require(presentation.beginSave()), document = SettingsSummaryDocument(data: attempt.snapshot.data)
            #expect(document.data == snapshot.data && attempt.snapshot.id == snapshot.id)
            #expect(try Data(contentsOf: fixture.file) == before)
            #expect(fixture.registrationCalls == calls && fixture.clipboardReads == 0 && fixture.copies.isEmpty)
            session.finishSettingsSummarySave(presentation.id, attemptID: attempt.id, outcome: .cancelled)
            #expect(presentation.canSave && presentation.notice.rendered().isEmpty)
        }
    }
    @Test func settingsChangesDoNotAlterReviewedOrSavingBytesUntilExplicitRefresh() async throws {
        try await withFixture { fixture in
            let session = SettingsSession(store: fixture.store); session.prepareSettingsSummary(in: fixture.store)
            let presentation = try #require(session.settingsSummaryExport), old = try #require(presentation.snapshot)
            var next = fixture.store.configuration; next.language = "en"; next.appearance = "dark"
            #expect(fixture.store.commitShortcutConfiguration(next))
            let attempt = try #require(presentation.beginSave())
            #expect(attempt.snapshot.data == old.data && presentation.snapshot?.id == old.id)
            session.refreshSettingsSummary(presentation.id, in: fixture.store)
            #expect(presentation.snapshot?.id == old.id)
            session.finishSettingsSummarySave(presentation.id, attemptID: attempt.id, outcome: .cancelled)
            session.refreshSettingsSummary(presentation.id, in: fixture.store)
            #expect(presentation.snapshot?.id != old.id && presentation.snapshot?.data != old.data)
        }
    }
    @Test func choicesRequireAnAccuratePreviewAndFailedPreparationKeepsOldBytes() async throws {
        try await withFixture { fixture in
            let session = SettingsSession(store: fixture.store); session.prepareSettingsSummary(in: fixture.store)
            let presentation = try #require(session.settingsSummaryExport), old = try #require(presentation.snapshot)
            presentation.setSection(.configurationCounts, selected: true)
            #expect(presentation.needsPreview && !presentation.canSave && presentation.beginSave() == nil)
            session.refreshSettingsSummary(presentation.id, in: fixture.store)
            #expect(!presentation.needsPreview && presentation.canSave && presentation.snapshot?.id != old.id)
            let valid = try #require(presentation.snapshot)
            for section in SettingsSummarySection.allCases { presentation.setSection(section, selected: false) }
            #expect(!presentation.refresh(configuration: fixture.store.configuration, clipboard: .init(primaryAction: .insert, separator: .newline)))
            #expect(presentation.snapshot?.data == valid.data && !presentation.canSave && !presentation.notice.rendered().isEmpty)
        }
    }
    @Test func savingRejectsReentryAndLateCallbacksCannotFinishAnotherAttempt() async throws {
        try await withFixture { fixture in
            let session = SettingsSession(store: fixture.store); session.prepareSettingsSummary(in: fixture.store)
            let presentation = try #require(session.settingsSummaryExport), first = try #require(presentation.beginSave())
            presentation.setSection(.launcherShortcut, selected: true); session.closeSettingsSummary(presentation.id)
            #expect(presentation.sections == [.basicPreferences] && session.settingsSummaryExport?.id == presentation.id && presentation.beginSave() == nil)
            #expect(!presentation.finishSave(UUID(), outcome: .saved) && presentation.isSaving)
            session.finishSettingsSummarySave(presentation.id, attemptID: first.id, outcome: .failed)
            #expect(!presentation.isSaving && presentation.canSave && !presentation.notice.rendered().isEmpty)
            let retry = try #require(presentation.beginSave())
            #expect(retry.id != first.id && retry.snapshot.id == first.snapshot.id && retry.snapshot.data == first.snapshot.data)
            session.finishSettingsSummarySave(presentation.id, attemptID: first.id, outcome: .saved)
            #expect(presentation.saveAttempt?.id == retry.id && presentation.notice.rendered().isEmpty)
            session.finishSettingsSummarySave(presentation.id, attemptID: retry.id, outcome: .cancelled)
            #expect(presentation.notice.rendered().isEmpty && presentation.canSave)
            let final = try #require(presentation.beginSave()); presentation.finishSave(final.id, outcome: .saved)
            #expect(!presentation.notice.rendered().isEmpty && presentation.canSave)
        }
    }
    @Test func closingWaitsForDismissalAndOldCompletionCannotPolluteAReopenedReview() async throws {
        try await withFixture { fixture in
            let session = SettingsSession(store: fixture.store); session.prepareSettingsSummary(in: fixture.store)
            let old = try #require(session.settingsSummaryExport), oldAttempt = try #require(old.beginSave())
            session.settingsSummaryDidAppear(old.id)
            session.setVisible(false)
            #expect(old.invalidated && old.snapshot == nil && old.saveAttempt == nil && session.settingsSummaryExport?.id == old.id)
            session.setVisible(true); session.prepareSettingsSummary(in: fixture.store)
            #expect(session.settingsSummaryExport?.id == old.id && !session.canBeginSavedItemEditor)
            session.settingsSummaryDidDismiss(old.id); session.prepareSettingsSummary(in: fixture.store)
            let current = try #require(session.settingsSummaryExport), currentAttempt = try #require(current.beginSave())
            session.settingsSummaryDidAppear(current.id)
            session.finishSettingsSummarySave(old.id, attemptID: oldAttempt.id, outcome: .saved)
            #expect(current.saveAttempt?.id == currentAttempt.id && current.notice.rendered().isEmpty)
            presentationCancel(session, current, currentAttempt)
            session.closeSettingsSummary(current.id)
            #expect(current.invalidated && current.snapshot == nil && !session.canBeginSavedItemEditor)
            session.settingsSummaryDidDismiss(old.id)
            #expect(session.settingsSummaryDismissing && session.settingsSummaryExport?.id == current.id && !session.canBeginSavedItemEditor)
            session.beginNewCommand(); #expect(session.editedCommand == nil)
            session.settingsSummaryDidDismiss(current.id); #expect(session.canBeginSavedItemEditor)
        }
    }
    @Test func exportAndExistingEditorsHaveMutualOwnershipBeforePendingReviewsAreConsumed() async throws {
        try await withFixture { fixture in
            let target = try fixture.add(.snippet), store = fixture.store, session = SettingsSession(store: fixture.store)
            session.beginNewCommand(); session.prepareSettingsSummary(in: store); #expect(session.settingsSummaryExport == nil)
            session.editedCommand = nil; session.prepareSettingsSummary(in: store)
            let presentation = try #require(session.settingsSummaryExport)
            session.settingsSummaryDidAppear(presentation.id)
            let command = SavedCommand(name: "Synthetic pending", executable: "/usr/bin/printf"), runID = UUID()
            try store.enqueueCommandReview(command, runID: runID)
            session.beginNewCommand(); session.beginNewAction(); session.editCommand(command)
            session.editAction(.init(name: "Synthetic", prompt: "Synthetic")); session.prepareRemoval(target, in: store)
            session.prepareDeletedToolPreferences(in: store); session.beginDesktopWorkspace(in: store)
            #expect(session.editedCommand == nil && session.editedAction == nil && session.savedItemRemoval == nil && session.deletedToolPreferencesReview == nil && session.desktopWorkspaceEditor == nil)
            #expect(!session.beginNextCommandReview(in: store) && store.pendingCommandReviews.map(\.id) == [runID] && store.activeCommandReviews.isEmpty)
            session.closeSettingsSummary(presentation.id)
            #expect(!session.beginNextCommandReview(in: store))
            session.settingsSummaryDidDismiss(presentation.id); #expect(session.beginNextCommandReview(in: store))
            #expect(store.pendingCommandReviews.isEmpty && store.activeCommandReviews[runID] != nil)
            session.editedCommandSourceRunID = nil; session.editedCommand = nil
        }
    }
    @Test func closingBeforeTheSheetAppearsDoesNotWaitForAnImpossibleDismissCallback() async throws {
        try await withFixture { fixture in
            let session = SettingsSession(store: fixture.store); session.prepareSettingsSummary(in: fixture.store)
            let old = try #require(session.settingsSummaryExport)
            session.setVisible(false)
            #expect(old.invalidated && old.snapshot == nil && session.settingsSummaryExport == nil && !session.settingsSummaryDismissing)
            session.setVisible(true); session.prepareSettingsSummary(in: fixture.store)
            let current = try #require(session.settingsSummaryExport)
            session.settingsSummaryDidAppear(old.id); session.settingsSummaryDidDismiss(old.id)
            #expect(session.settingsSummaryExport?.id == current.id && !old.appeared && current.snapshot != nil)
            session.closeSettingsSummary(current.id)
            #expect(session.settingsSummaryExport == nil && session.canBeginSavedItemEditor)
        }
    }
    private func presentationCancel(_ session: SettingsSession, _ presentation: SettingsSummaryPresentation, _ attempt: SettingsSummarySaveAttempt) {
        session.finishSettingsSummarySave(presentation.id, attemptID: attempt.id, outcome: .cancelled)
    }
}
