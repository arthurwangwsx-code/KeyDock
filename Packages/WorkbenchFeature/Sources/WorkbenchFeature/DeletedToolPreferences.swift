import Foundation
import Combine
import MacAdapters

struct DeletedToolPreference: Identifiable, Equatable {
    let id: String
    let target: SavedItemTarget
    let shortcut: HotkeyBinding?
    let favorite: Bool
    let alias: Bool
    let recent: Bool
    let fingerprint: String
    var title: String {
        switch target { case .snippet: L("Snippet"); case .webAction: L("URL action"); case .collection: L("Collection"); default: L("Unavailable action") }
    }
}

struct DeletedToolPreferenceReview: Identifiable {
    let id = UUID()
    let entries: [DeletedToolPreference]
}

@MainActor final class DeletedToolPreferencePresentation: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var review: DeletedToolPreferenceReview
    init(_ review: DeletedToolPreferenceReview) { self.review = review }
    func update(_ review: DeletedToolPreferenceReview) { self.review = review }
}

private struct DeletedToolPreferenceValues: Encodable {
    let shortcut: HotkeyBinding?
    let favorite: Bool
    let alias: String?
    let recent: Date?
}

extension WorkbenchModel {
    /// 只识别三种完整UUID命名空间；禁用贡献、未知ID和集合中的引用均不在清理范围。
    private func deletedToolPreferenceTargets() -> [(String, SavedItemTarget)] {
        let snippets = Set(configuration.snippets.map(\.id)), web = Set(configuration.webActions.map(\.id)), collections = Set(configuration.collections.map(\.id))
        let ids = Set(configuration.commandShortcuts.keys).union(configuration.preferences.favorites)
            .union(configuration.preferences.aliases.keys).union(configuration.preferences.recent.keys)
        return ids.sorted().compactMap { id in
            let parts = id.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].utf8.count == 36, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "snippet" where !snippets.contains(uuid): return (id, .snippet(uuid))
            case "web" where !web.contains(uuid): return (id, .webAction(uuid))
            case "collection" where !collections.contains(uuid): return (id, .collection(uuid))
            default: return nil
            }
        }
    }
    var hasDeletedToolPreferences: Bool { !deletedToolPreferenceTargets().isEmpty }
    func reviewDeletedToolPreferences() -> DeletedToolPreferenceReview {
        let entries = deletedToolPreferenceTargets().compactMap { id, target -> DeletedToolPreference? in
            let values = DeletedToolPreferenceValues(shortcut: configuration.commandShortcuts[id], favorite: configuration.preferences.favorites.contains(id),
                alias: configuration.preferences.aliases[id], recent: configuration.preferences.recent[id])
            guard let fingerprint = objectFingerprint(values) else { return nil }
            return .init(id: id, target: target, shortcut: values.shortcut, favorite: values.favorite, alias: values.alias != nil, recent: values.recent != nil, fingerprint: fingerprint)
        }
        return .init(entries: entries)
    }
    @discardableResult func clearDeletedToolPreferences(_ reviewed: DeletedToolPreferenceReview) -> Bool {
        guard !isShuttingDown else { settingsNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return false }
        guard reviewDeletedToolPreferences().entries == reviewed.entries else {
            settingsNoticeMessage = noticeKey("Deleted tool preferences changed. Review them again before clearing.")
            return false
        }
        guard !reviewed.entries.isEmpty else { settingsNoticeMessage = noticeKey("There are no deleted tool preferences to clear."); return false }
        var next = configuration
        for entry in reviewed.entries {
            next.commandShortcuts[entry.id] = nil; next.preferences.favorites.remove(entry.id)
            next.preferences.aliases[entry.id] = nil; next.preferences.recent[entry.id] = nil
        }
        return commitShortcutConfiguration(next)
    }
}

extension SettingsSession {
    func prepareDeletedToolPreferences(in store: WorkbenchModel) {
        guard canBeginSavedItemEditor else { return }
        let review = store.reviewDeletedToolPreferences()
        guard !review.entries.isEmpty else { store.settingsNoticeMessage = noticeKey("There are no deleted tool preferences to clear."); return }
        store.settingsNoticeMessage = .none
        deletedToolPreferencesReview = DeletedToolPreferencePresentation(review)
    }
    func refreshDeletedToolPreferences(_ presentationID: UUID, in store: WorkbenchModel) {
        guard !store.isShuttingDown, let presentation = deletedToolPreferencesReview, presentation.id == presentationID else { return }
        presentation.update(store.reviewDeletedToolPreferences()); store.settingsNoticeMessage = .none
    }
    func cancelDeletedToolPreferences(_ presentationID: UUID) {
        guard deletedToolPreferencesReview?.id == presentationID else { return }; deletedToolPreferencesReview = nil
    }
    @discardableResult func confirmDeletedToolPreferences(_ reviewID: UUID, in store: WorkbenchModel) -> Bool {
        guard let presentation = deletedToolPreferencesReview, presentation.review.id == reviewID,
              store.clearDeletedToolPreferences(presentation.review) else { return false }
        deletedToolPreferencesReview = nil
        return true
    }
}
