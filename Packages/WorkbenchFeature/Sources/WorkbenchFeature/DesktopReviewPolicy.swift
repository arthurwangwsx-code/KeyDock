import Foundation
import MacAdapters

/// Review配置只表示外观与一项绑定；不解码或清洗普通配置中的执行定义。
enum DesktopReviewConfigurationCodec {
    private struct Payload: Codable {
        let formatVersion: Int
        let language: String
        let appearance: String
        let clipboardShortcut: HotkeyBinding?
        enum CodingKeys: String, CodingKey { case formatVersion, language, appearance, clipboardShortcut }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(language, forKey: .language)
            try c.encode(appearance, forKey: .appearance)
            try c.encode(clipboardShortcut, forKey: .clipboardShortcut)
        }
    }
    static func baseline() -> AppConfiguration {
        var value = AppConfiguration()
        value.launcherShortcut = nil
        value.agents = []
        return value
    }
    static func validate(_ value: AppConfiguration) throws {
        let defaults = baseline()
        guard value.schemaVersion == 1, ["system", "en", "zh-Hans"].contains(value.language),
              ["system", "light", "dark"].contains(value.appearance), value.launcherShortcut == nil,
              Set(value.commandShortcuts.keys).isSubset(of: ["utility.clipboard"]),
              value.commandShortcuts.values.allSatisfy(\.isValid),
              value.preferences.aliases.isEmpty, value.preferences.favorites.isEmpty, value.preferences.recent.isEmpty,
              value.savedCommands.isEmpty, value.disabledContributions.isEmpty, value.aiActions.isEmpty, value.agents.isEmpty,
              value.workflows.isEmpty, value.snippets.isEmpty, value.webActions.isEmpty, value.collections.isEmpty,
              value.searchFolders.isEmpty, value.mcpServers.isEmpty, value.aiRates.isEmpty,
              !value.activityEnabled, !value.taskMaterialRetentionEnabled, !value.clipboardEnabled, !value.localHTTP,
              value.endpoint.isEmpty, value.model.isEmpty, value.tokenLimitParameter == defaults.tokenLimitParameter,
              value.clipboardExclusions == defaults.clipboardExclusions else { throw DesktopReviewError.invalidScope }
    }
    static func load(_ data: Data?) throws -> AppConfiguration {
        guard let data else { return baseline() }
        guard !data.isEmpty, data.count <= 65_536 else { throw DesktopReviewError.invalidScope }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        guard value.formatVersion == 1 else { throw DesktopReviewError.invalidScope }
        var configuration = baseline()
        configuration.language = value.language; configuration.appearance = value.appearance
        configuration.commandShortcuts["utility.clipboard"] = value.clipboardShortcut
        // 固定canonical字节合同同时拒绝未知／重复key及缺失的null字段，不静默清洗。
        guard try encode(configuration) == data else { throw DesktopReviewError.invalidScope }
        return configuration
    }
    static func encode(_ value: AppConfiguration) throws -> Data {
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(formatVersion: 1, language: value.language,
            appearance: value.appearance, clipboardShortcut: value.commandShortcuts["utility.clipboard"]))
        guard data.count <= 65_536 else { throw DesktopReviewError.invalidScope }
        return data
    }
}

extension WorkbenchModel {
    public var isDesktopReview: Bool { desktopReviewScope != nil }
    public var desktopReviewAvailable: Bool {
        guard !isShuttingDown, let scope = desktopReviewScope, scope.isCurrent else { return false }
        do { try DesktopReviewConfigurationCodec.validate(configuration); return true } catch { return false }
    }
    func requireGeneralRuntime() throws {
        guard !isDesktopReview else { throw DesktopReviewError.unavailable }
    }
    func desktopReviewUnavailable() {
        let message = noticeKey("Desktop review only allows clipboard history actions.")
        settingsNoticeMessage = message; launcherNoticeMessage = message; workspaceNoticeMessage = message
    }
    /// Review不调用按路径抓快照／删除的普通补偿；持久结果不确定时停用整个scope。
    @discardableResult func commitDesktopReviewConfiguration(_ next: AppConfiguration) -> Bool {
        guard let scope = desktopReviewScope, desktopReviewAvailable else { desktopReviewUnavailable(); return false }
        let bytes: Data
        do { bytes = try DesktopReviewConfigurationCodec.encode(next) }
        catch { desktopReviewUnavailable(); return false }
        let previous = configuration
        let changed = ShortcutPlan.entries(previous) != ShortcutPlan.entries(next)
        var registered = false
        do {
            if changed {
                guard let onShortcutConfigurationChanged else { throw DesktopReviewError.unavailable }
                try onShortcutConfigurationChanged(next); registered = true
            }
        } catch {
            if (error as? HotkeyRegistrationError)?.restorationFailed == true { shortcutsUnavailable = true }
            settingsNoticeMessage = noticeKey("Shortcut could not be registered. Previous settings were kept.")
            return false
        }
        do {
            guard scope.isCurrent else { throw DesktopReviewError.unavailable }
            try scope.writeConfiguration(bytes, to: directory.appendingPathComponent("configuration.json"))
            guard scope.isCurrent else { throw DesktopReviewError.unavailable }
        } catch {
            if registered {
                do {
                    guard let onShortcutConfigurationChanged else { throw DesktopReviewError.unavailable }
                    try onShortcutConfigurationChanged(previous)
                } catch { shortcutsUnavailable = true }
            }
            scope.revoke()
            settingsNoticeMessage = noticeKey("Desktop review settings could not be confirmed. Close this review and start a new session.")
            return false
        }
        configuration = next; applyConfigurationEffects(); settingsNoticeMessage = .none
        return true
    }
}
