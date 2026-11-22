import Foundation
import CommandCore
import ExecutionCore
import MacAdapters

public enum AIInputSource: String, Codable, CaseIterable, Sendable { case selection, clipboard, manual }
public enum AIOutputMode: String, Codable, CaseIterable, Sendable { case display, copy }
public struct AIActionPreset: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var prompt: String
    public var input: AIInputSource = .selection
    public var output: AIOutputMode = .display
    public var modelOverride: String = ""
    public var shortcut: HotkeyBinding?
    public init(name: String, prompt: String) { self.name = name; self.prompt = prompt }
}
public struct AppConfiguration: Codable, Sendable {
    public var schemaVersion = 1
    public var preferences = CommandPreferences()
    public var launcherShortcut: HotkeyBinding? = HotkeyBinding()
    public var commandShortcuts: [String: HotkeyBinding] = [:]
    public var savedCommands: [SavedCommand] = []
    public var aiActions: [AIActionPreset] = []
    public var endpoint = ""
    public var model = ""
    public var localHTTP = false
    public var tokenLimitParameter = "max_completion_tokens"
    public var clipboardEnabled = false
    public var clipboardExclusions = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess"]
    public init() {}
}

public struct RunningTaskItem: Identifiable {
    public let id: UUID
    public var title: String
    public var state: String
    public var output = ""
    public var exitCode: Int32?
    public var startedAt = Date()
    public var finishedAt: Date?
    public var isRunning: Bool { finishedAt == nil }
}

public enum WorkbenchSection: String, CaseIterable { case search, clipboard, commands, ai, tasks, settings }

func L(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }
