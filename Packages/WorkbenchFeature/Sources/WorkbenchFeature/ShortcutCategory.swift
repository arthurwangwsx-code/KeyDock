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
        case .applications: item.kind == .application
        case .windows: item.payload.hasPrefix("window-layout.")
        case .ai: item.kind == .ai
        case .commands: item.kind == .command
        case .tools: item.kind == .utility && !item.payload.hasPrefix("window-layout.")
        }
    }
}
