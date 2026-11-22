import Foundation

public enum CommandKind: String, Codable, Sendable, CaseIterable {
    case application
    case window
    case command
    case clipboard
    case ai
    case utility
}

public struct CommandItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var keywords: [String]
    public var kind: CommandKind
    public var payload: String

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        keywords: [String] = [],
        kind: CommandKind,
        payload: String = ""
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.kind = kind
        self.payload = payload
    }
}

public struct CommandPreferences: Codable, Sendable {
    /// 键为命令 ID，值为用户设置的搜索别名。
    public var aliases: [String: String]
    public var favorites: Set<String>
    public var recent: [String: Date]

    public init(
        aliases: [String: String] = [:],
        favorites: Set<String> = [],
        recent: [String: Date] = [:]
    ) {
        self.aliases = aliases
        self.favorites = favorites
        self.recent = recent
    }
}
