import Foundation
import Testing
import CommandCore
import ExecutionCore
import MacAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct DeletedToolPreferenceTests {
    private func withFixture(_ body: (SavedToolFixture) async throws -> Void) async throws {
        let fixture = try SavedToolFixture()
        do { try await body(fixture); await fixture.cleanup() } catch { await fixture.cleanup(); throw error }
    }
    private func missing(_ kind: String = "snippet") -> String { kind + "." + UUID().uuidString }
    private func addPreferences(_ ids: [String], in fixture: SavedToolFixture, shortcuts: Bool = true) -> Bool {
        var next = fixture.store.configuration
        for (index, id) in ids.enumerated() {
            if shortcuts { next.commandShortcuts[id] = HotkeyBinding(keyCode: UInt32(index + 2)) }
            next.preferences.favorites.insert(id); next.preferences.aliases[id] = "Synthetic alias é"
            next.preferences.recent[id] = Date(timeIntervalSince1970: 1)
        }
        return fixture.store.commitShortcutConfiguration(next)
    }

    @Test func legacySchemaOneAndPreferencesWithoutHotkeysAreVisibleAndExplicitlyCleared() async throws {
        try await withFixture { fixture in
            let store = fixture.store, ids = [missing(), missing("web"), missing("collection")]
            #expect(addPreferences(ids, in: fixture, shortcuts: false))
            var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any])
            legacy["schemaVersion"] = 1
            // 真实v1没有模型策略或撤权revision，不能仅改版本号伪装新版数据。
            legacy.removeValue(forKey: "aiModelSettings"); legacy.removeValue(forKey: "aiSettingsRevision")
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(decoded.preferences.favorites.isSuperset(of: ids) && ids.allSatisfy { decoded.preferences.aliases[$0] != nil })
            #expect(store.commitShortcutConfiguration(decoded))
            let session = SettingsSession(store: store)
            session.prepareDeletedToolPreferences(in: store)
            let presentation = try #require(session.deletedToolPreferencesReview)
            #expect(presentation.review.entries.map(\.id) == ids.sorted())
            #expect(presentation.review.entries.allSatisfy { $0.shortcut == nil && $0.favorite && $0.alias && $0.recent })
            #expect(session.confirmDeletedToolPreferences(presentation.review.id, in: store))
            #expect(!store.hasDeletedToolPreferences && session.deletedToolPreferencesReview == nil)
            let disk = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fixture.file))
            #expect(ids.allSatisfy { disk.preferences.aliases[$0] == nil && disk.preferences.recent[$0] == nil && !disk.preferences.favorites.contains($0) })
        }
    }

    @Test(arguments: ["shortcut", "favorite", "alias", "recent"])
    func aSingleOrphanContainerIsEnoughToOfferCleanup(field: String) async throws {
        try await withFixture { fixture in
            let store = fixture.store, id = missing()
            var next = store.configuration
            switch field {
            case "shortcut": next.commandShortcuts[id] = HotkeyBinding(keyCode: 2)
            case "favorite": next.preferences.favorites.insert(id)
            case "alias": next.preferences.aliases[id] = ""
            default: next.preferences.recent[id] = Date(timeIntervalSince1970: 1)
            }
            #expect(store.commitShortcutConfiguration(next) && store.hasDeletedToolPreferences)
            let review = store.reviewDeletedToolPreferences(), entry = try #require(review.entries.first)
            #expect(review.entries.count == 1 && entry.id == id)
            #expect((entry.shortcut != nil) == (field == "shortcut") && entry.favorite == (field == "favorite") && entry.alias == (field == "alias") && entry.recent == (field == "recent"))
            #expect(store.clearDeletedToolPreferences(review) && !store.hasDeletedToolPreferences)
        }
    }

    @Test func onlyExactMissingUUIDToolsAreClearedAndOtherDefinitionsAndReferencesRemain() async throws {
        try await withFixture { fixture in
            let store = fixture.store, current = try SavedToolKind.allCases.map { try fixture.add($0).commandID }
            let removed = [missing(), missing("web"), missing("collection")]
            let preserved = current + [missing("future"), missing("command"), removed[0] + ".other", "snippet.not-a-uuid", "utility.calculator.result"]
            #expect(addPreferences(removed + preserved, in: fixture))
            var next = store.configuration
            next.disabledContributions.insert(BuiltinContributionID.calculator)
            // 旧集合中的失效引用供用户显式编辑；偏好清理不改写集合内容。
            next.collections.append(try CommandCollection(name: "Synthetic old reference", commandIDs: [removed[0]]))
            #expect(store.commitShortcutConfiguration(next))
            let definitions = store.configuration.collections, review = store.reviewDeletedToolPreferences()
            #expect(review.entries.map(\.id) == removed.sorted())
            #expect(store.clearDeletedToolPreferences(review))
            #expect(store.configuration.collections == definitions)
            #expect(preserved.allSatisfy { store.configuration.preferences.favorites.contains($0) && store.configuration.preferences.aliases[$0] != nil && store.configuration.commandShortcuts[$0] != nil })
            #expect(removed.allSatisfy { store.configuration.commandShortcuts[$0] == nil && !store.configuration.preferences.favorites.contains($0) })
            #expect(!fixture.runtime.contains { removed.contains($0.commandID ?? "") })
            #expect(!fixture.runtime.contains { $0.commandID == "utility.calculator.result" })
        }
    }

    @Test func changingAliasBytesOrAddingAnOrphanRequiresNewReview() async throws {
        try await withFixture { fixture in
            let store = fixture.store, first = missing(), second = missing("web"), session = SettingsSession(store: fixture.store)
            #expect(addPreferences([first], in: fixture))
            session.prepareDeletedToolPreferences(in: store)
            let presentation = try #require(session.deletedToolPreferencesReview), old = presentation.review
            var next = store.configuration; next.preferences.aliases[first] = "Synthetic alias e\u{301}"
            #expect(store.commitShortcutConfiguration(next))
            let bytes = try Data(contentsOf: fixture.file)
            #expect(!session.confirmDeletedToolPreferences(old.id, in: store))
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(session.deletedToolPreferencesReview?.id == presentation.id)
            session.refreshDeletedToolPreferences(presentation.id, in: store)
            #expect(presentation.review.id != old.id && !session.confirmDeletedToolPreferences(old.id, in: store))
            let reviewed = presentation.review
            #expect(addPreferences([second], in: fixture, shortcuts: false))
            #expect(!session.confirmDeletedToolPreferences(reviewed.id, in: store))
            session.refreshDeletedToolPreferences(presentation.id, in: store)
            #expect(presentation.review.entries.count == 2 && session.confirmDeletedToolPreferences(presentation.review.id, in: store))
        }
    }

    @Test func aReintroducedDefinitionIsKeptAndRefreshCanBecomeEmpty() async throws {
        try await withFixture { fixture in
            let store = fixture.store, id = UUID(), key = "snippet." + id.uuidString, session = SettingsSession(store: fixture.store)
            #expect(addPreferences([key], in: fixture))
            session.prepareDeletedToolPreferences(in: store)
            let presentation = try #require(session.deletedToolPreferencesReview), old = presentation.review
            var next = store.configuration; next.snippets.append(try SnippetDefinition(id: id, name: "Synthetic restored definition", text: "Synthetic body"))
            #expect(store.commitShortcutConfiguration(next))
            #expect(!session.confirmDeletedToolPreferences(old.id, in: store))
            session.refreshDeletedToolPreferences(presentation.id, in: store)
            #expect(presentation.review.entries.isEmpty && !session.confirmDeletedToolPreferences(presentation.review.id, in: store))
            #expect(store.configuration.preferences.aliases[key] != nil && store.configuration.commandShortcuts[key] != nil)
            session.cancelDeletedToolPreferences(presentation.id)
            #expect(session.deletedToolPreferencesReview == nil && !store.hasDeletedToolPreferences)
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func storageFailureRestoresExactFileAndRuntimeAndKeepsTheReview(failure: InterfaceWriteRelay.Failure) async throws {
        try await withFixture { fixture in
            let store = fixture.store, key = missing(), session = SettingsSession(store: fixture.store)
            #expect(addPreferences([key], in: fixture))
            session.prepareDeletedToolPreferences(in: store)
            let presentation = try #require(session.deletedToolPreferencesReview)
            let bytes = try Data(contentsOf: fixture.file), runtime = fixture.runtime
            fixture.relay.failure = failure
            #expect(!session.confirmDeletedToolPreferences(presentation.review.id, in: store))
            #expect(try Data(contentsOf: fixture.file) == bytes)
            #expect(fixture.runtime == runtime && !store.shortcutsUnavailable && session.deletedToolPreferencesReview?.id == presentation.id)
            #expect(store.configuration.preferences.aliases[key] != nil && !store.settingsNotice.isEmpty)
            #expect(session.confirmDeletedToolPreferences(presentation.review.id, in: store))
        }
    }

    @Test func registrationFailureAndIncompleteRollbackKeepOrphansAndReportFailure() async throws {
        try await withFixture { fixture in
            let store = fixture.store, key = missing()
            #expect(addPreferences([key], in: fixture))
            let review = store.reviewDeletedToolPreferences(), bytes = try Data(contentsOf: fixture.file), runtime = fixture.runtime
            fixture.failRegistration = true
            #expect(!store.clearDeletedToolPreferences(review) && fixture.runtime == runtime)
            #expect(try Data(contentsOf: fixture.file) == bytes)
            fixture.failRegistration = false; fixture.registrationCalls = 0; fixture.failRestoration = true; fixture.relay.failure = .after
            #expect(!store.clearDeletedToolPreferences(review) && store.shortcutsUnavailable)
            #expect(store.configuration.commandShortcuts[key] != nil && store.configuration.preferences.aliases[key] != nil)
            #expect(store.settingsNoticeMessage == noticeKey("Shortcut changes could not be saved and rollback was incomplete. Check the saved shortcuts before retrying."))
        }
    }

    @Test func staleButtonsAndOtherSettingsEditorsCannotReplaceTheCurrentReview() async throws {
        try await withFixture { fixture in
            let store = fixture.store, key = missing(), session = SettingsSession(store: fixture.store)
            #expect(addPreferences([key], in: fixture, shortcuts: false))
            session.prepareDeletedToolPreferences(in: store)
            let old = try #require(session.deletedToolPreferencesReview)
            session.cancelDeletedToolPreferences(old.id); session.prepareDeletedToolPreferences(in: store)
            let current = try #require(session.deletedToolPreferencesReview)
            session.beginNewCommand(); session.beginNewAction()
            #expect(session.editedCommand == nil && session.editedAction == nil)
            #expect(!session.confirmDeletedToolPreferences(old.review.id, in: store))
            session.cancelDeletedToolPreferences(old.id)
            #expect(session.deletedToolPreferencesReview?.id == current.id)
            let target = try fixture.add(.snippet)
            session.prepareRemoval(target, in: store)
            #expect(session.savedItemRemoval == nil)
            session.cancelDeletedToolPreferences(current.id)
            session.beginNewCommand(); session.prepareDeletedToolPreferences(in: store)
            #expect(session.editedCommand != nil && session.deletedToolPreferencesReview == nil)
        }
    }

    @Test func aLateCommandReviewCannotConsumePendingOwnershipWhileCleanupIsOpen() async throws {
        try await withFixture { fixture in
            let store = fixture.store, session = SettingsSession(store: fixture.store), runID = UUID()
            #expect(addPreferences([missing()], in: fixture, shortcuts: false))
            session.prepareDeletedToolPreferences(in: store)
            let presentation = try #require(session.deletedToolPreferencesReview)
            let command = SavedCommand(name: "Synthetic pending review", executable: "/usr/bin/printf", workingDirectory: fixture.directory.path)
            try store.enqueueCommandReview(command, runID: runID)
            #expect(!session.canBeginSavedItemEditor && !session.beginNextCommandReview(in: store))
            #expect(store.pendingCommandReviews.map(\.id) == [runID] && store.activeCommandReviews.isEmpty)
            #expect(session.editedCommand == nil && session.deletedToolPreferencesReview?.id == presentation.id)
            session.cancelDeletedToolPreferences(presentation.id)
            #expect(session.beginNextCommandReview(in: store))
            #expect(store.pendingCommandReviews.isEmpty && store.activeCommandReviews[runID] != nil)
            #expect(session.editedCommand?.id == command.id && session.editedCommandSourceRunID == runID)
            session.editedCommand = nil; session.editedCommandSourceRunID = nil
            #expect(store.activeCommandReviews.isEmpty)
        }
    }
}
