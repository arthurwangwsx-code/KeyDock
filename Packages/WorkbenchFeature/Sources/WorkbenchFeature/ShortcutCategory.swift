import CommandCore

public enum ShortcutCategory: CaseIterable {
    case all, applications, windows, ai, commands, tools
    public var title: String {
        switch self {
        case .all: L("All actions")
        case .applications: L("Applications")
        case .windows: L("Window management")
        case .ai: L("AI Actions")
        case .commands: L("Commands")
        case .tools: L("Tools")
        }
    }
    func contains(_ item: CommandItem) -> Bool {
        switch self {
        case .all: true
        case .applications: item.kind == .application || item.payload.hasPrefix("application-action.")
        case .windows: item.payload.hasPrefix("desktop-workspace.") || item.id == "utility.desktop-workspaces" || item.payload.hasPrefix("window-layout.") || item.payload.hasPrefix("window-command.")
        case .ai: item.kind == .ai
        case .commands: item.kind == .command
        case .tools: item.kind == .utility && !item.payload.hasPrefix("desktop-workspace.") && item.id != "utility.desktop-workspaces" && !item.payload.hasPrefix("window-layout.") && !item.payload.hasPrefix("window-command.") && !item.payload.hasPrefix("application-action.")
        }
    }
}
