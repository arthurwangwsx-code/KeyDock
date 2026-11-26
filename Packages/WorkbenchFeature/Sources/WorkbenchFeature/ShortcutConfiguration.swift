import Foundation
import MacAdapters

public struct ShortcutPlanEntry: Hashable, Sendable {
    public let id: UInt32
    public let binding: HotkeyBinding
    public let commandID: String?
}

/// 逻辑槽位按稳定顺序生成，不使用可能碰撞的命令哈希；传输 token 由 Center 独立管理。
public enum ShortcutPlan {
    public static func entries(_ configuration: AppConfiguration) -> [ShortcutPlanEntry] {
        guard let manifests = try? BuiltinContributionManifests.all() else { return [] }
        var result: [ShortcutPlanEntry] = []
        if let binding = configuration.launcherShortcut { result.append(.init(id: 1, binding: binding, commandID: nil)) }
        // 保存的profile热键走专用桌面入口，不经过通用Launcher选区捕获。
        var commands = configuration.commandShortcuts.filter { !$0.key.hasPrefix("ai.") }
        for action in configuration.aiActions {
            if let binding = action.shortcut { commands["ai." + action.id.uuidString] = binding }
        }
        let effective = commands.keys.filter { BuiltinContributionManifests.isCommandEnabled($0,disabled:configuration.disabledContributions,manifests:manifests) }.sorted()
        for (offset, commandID) in effective.enumerated() {
            result.append(.init(id: UInt32(offset) + 2, binding: commands[commandID]!, commandID: commandID))
        }
        return result
    }
}

private enum ShortcutConfigurationError: Error { case runtimeUnavailable }

extension WorkbenchModel {
    @discardableResult public func setLauncherShortcut(_ binding: HotkeyBinding?) -> Bool {
        guard !isDesktopReview else { desktopReviewUnavailable(); return false }
        var next = configuration; next.launcherShortcut = binding
        return commitShortcutConfiguration(next)
    }
    @discardableResult func commitShortcutConfiguration(_ next: AppConfiguration) -> Bool {
        if isDesktopReview { return commitDesktopReviewConfiguration(next) }
        let next = preparedAIConfiguration(next)
        guard !isShuttingDown else { settingsNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return false }
        let previous = configuration
        let changed = ShortcutPlan.entries(previous) != ShortcutPlan.entries(next)
        let url = directory.appendingPathComponent("configuration.json")
        let previousFile: ConfigurationSnapshot
        let bytes: Data
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            bytes = try encoder.encode(next)
            // 保存原始字节/不存在状态；快照失败时不能先改变 OS 注册。
            previousFile = FileManager.default.fileExists(atPath: url.path) ? .bytes(try Data(contentsOf: url)) : .absent
        } catch {
            settingsNoticeMessage = noticeKey("Shortcut changes could not be saved. Previous settings were kept.")
            return false
        }
        var registeredCandidate = false, attemptedStorage = false
        do {
            if changed {
                guard let onShortcutConfigurationChanged else { shortcutsUnavailable = true; throw ShortcutConfigurationError.runtimeUnavailable }
                try onShortcutConfigurationChanged(next); registeredCandidate = true
            }
            attemptedStorage = true
            try configurationWriter(bytes, url)
            configuration = next; applyConfigurationEffects(); settingsNoticeMessage = .none
            return true
        } catch {
            var rollbackIncomplete = (error as? HotkeyRegistrationError)?.restorationFailed == true
            // writer 可能已经替换文件才抛错；文件补偿失败也不能跳过 OS 补偿。
            if attemptedStorage {
                do { try restoreConfiguration(previousFile, at: url) }
                catch { rollbackIncomplete = true }
            }
            if registeredCandidate {
                do {
                    guard let onShortcutConfigurationChanged else { throw ShortcutConfigurationError.runtimeUnavailable }
                    try onShortcutConfigurationChanged(previous)
                } catch { shortcutsUnavailable = true; rollbackIncomplete = true }
            }
            if rollbackIncomplete {
                settingsNoticeMessage = noticeKey("Shortcut changes could not be saved and rollback was incomplete. Check the saved shortcuts before retrying.")
            } else {
                settingsNoticeMessage = attemptedStorage
                    ? noticeKey("Shortcut changes could not be saved. Previous settings were kept.")
                    : noticeKey("Shortcut could not be registered. Previous settings were kept.")
            }
            return false
        }
    }
    public func retryShortcuts() {
        guard !isDesktopReview || desktopReviewAvailable else { desktopReviewUnavailable(); return }
        guard !isShuttingDown else { return }
        do {
            guard let onShortcutConfigurationChanged else { throw ShortcutConfigurationError.runtimeUnavailable }
            try onShortcutConfigurationChanged(configuration)
            shortcutsUnavailable = false; settingsNoticeMessage = .none
        } catch {
            shortcutsUnavailable = true
            settingsNoticeMessage = noticeKey("Shortcuts are inactive. Choose another shortcut or retry registration.")
        }
    }
}
