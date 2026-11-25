import Foundation
import CommandCore
import MacAdapters

enum SettingsSummarySection: String, CaseIterable, Sendable {
    case basicPreferences, launcherShortcut, configurationCounts
    var title: String {
        switch self {
        case .basicPreferences: L("Basic preferences")
        case .launcherShortcut: L("Launcher shortcut")
        case .configurationCounts: L("Main configuration counts (includes built-in definitions)")
        }
    }
}

struct ClipboardSummaryPreferences: Sendable {
    let primaryAction: ClipboardPrimaryAction
    let separator: ClipboardSeparator
}

struct FrozenSettingsSummary: Identifiable, Sendable {
    let id = UUID()
    let sections: Set<SettingsSummarySection>
    let data: Data
    var preview: String { String(decoding: data, as: UTF8.self) }
}

enum SettingsSummaryError: Error, Equatable { case noSections, tooLarge }

/// 显式投影允许的字段；不能先编码完整配置再删除可能含正文的字段。
enum SettingsSummaryProjection {
    static let maximumBytes = 65_536
    private struct Document: Encodable {
        let format = "KeyDock.settings-summary"
        let schemaVersion = 1
        let basicPreferences: BasicPreferences?
        let launcherShortcut: LauncherShortcut?
        let configurationCounts: ConfigurationCounts?
    }
    private struct BasicPreferences: Encodable {
        let language: String
        let appearance: String
        let clipboardRecordingEnabled: Bool
        let activityRecordingEnabled: Bool
        let clipboardPrimaryAction: String
        let clipboardSeparator: String
    }
    private struct LauncherShortcut: Encodable {
        let state: String
        let keyCode: UInt32?
        let modifiers: UInt32?
        init(_ binding: HotkeyBinding?) {
            guard let binding else { state = "disabled"; keyCode = nil; modifiers = nil; return }
            // Carbon的Command/Shift/Option/Control位；未知位和超范围keyCode不原样转出。
            guard binding.keyCode < 128, binding.modifiers != 0, binding.modifiers & ~UInt32(0x1B00) == 0 else {
                state = "invalid"; keyCode = nil; modifiers = nil; return
            }
            state = "configured"; keyCode = binding.keyCode; modifiers = binding.modifiers
        }
    }
    private struct ConfigurationCounts: Encodable {
        let savedCommands: Int, aiActions: Int, agents: Int, workflows: Int, snippets: Int
        let webActions: Int, collections: Int, searchFolders: Int, mcpServers: Int
        let aliases: Int, favorites: Int
        init(_ configuration: AppConfiguration) {
            savedCommands = configuration.savedCommands.count; aiActions = configuration.aiActions.count
            agents = configuration.agents.count; workflows = configuration.workflows.count; snippets = configuration.snippets.count
            webActions = configuration.webActions.count; collections = configuration.collections.count
            searchFolders = configuration.searchFolders.count; mcpServers = configuration.mcpServers.count
            aliases = configuration.preferences.aliases.count; favorites = configuration.preferences.favorites.count
        }
    }
    static func make(configuration: AppConfiguration, clipboard: ClipboardSummaryPreferences,
                     sections: Set<SettingsSummarySection>, maximumBytes: Int = maximumBytes) throws -> FrozenSettingsSummary {
        guard !sections.isEmpty else { throw SettingsSummaryError.noSections }
        let basic: BasicPreferences? = sections.contains(.basicPreferences) ? .init(
            language: ["system", "en", "zh-Hans"].contains(configuration.language) ? configuration.language : "unknown",
            appearance: ["system", "light", "dark"].contains(configuration.appearance) ? configuration.appearance : "unknown",
            clipboardRecordingEnabled: configuration.clipboardEnabled, activityRecordingEnabled: configuration.activityEnabled,
            clipboardPrimaryAction: clipboard.primaryAction.rawValue, clipboardSeparator: clipboard.separator.rawValue) : nil
        let document = Document(basicPreferences: basic,
            launcherShortcut: sections.contains(.launcherShortcut) ? .init(configuration.launcherShortcut) : nil,
            configurationCounts: sections.contains(.configurationCounts) ? .init(configuration) : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw SettingsSummaryError.tooLarge }
        return .init(sections: sections, data: data)
    }
}
