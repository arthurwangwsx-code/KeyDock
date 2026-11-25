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
    public var title: String { didSet { prepareTitle() } }
    public var subtitle: String { didSet { searchSubtitle = CommandSearch.normalize(subtitle) } }
    public var keywords: [String] { didSet { searchKeywords = keywords.map(CommandSearch.normalize) } }
    public var kind: CommandKind
    public var payload: String
    public var objectRevision: String?
    public var contribution: CommandContributionBinding?
    // 值类型派生缓存不参与编码、身份、相等或哈希；每个可变文本入口各自更新。
    private(set) var searchTitle = ""
    private(set) var searchTitleWords: [Substring] = []
    private(set) var searchSubtitle = ""
    private(set) var searchKeywords: [String] = []
    /// 只用于工程观察的逻辑UTF8规模，不是RSS或分配器内存用量。
    public var preparedSearchTextUTF8Bytes: Int { searchTitle.utf8.count + searchSubtitle.utf8.count + searchKeywords.reduce(0) { $0 + $1.utf8.count } }
    private mutating func prepareTitle() {
        searchTitle = CommandSearch.normalize(title); searchTitleWords = searchTitle.split(separator: " ")
    }

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        keywords: [String] = [],
        kind: CommandKind,
        payload: String = "",
        objectRevision: String? = nil,
        contribution: CommandContributionBinding? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.kind = kind
        self.payload = payload
        self.objectRevision = objectRevision
        self.contribution = contribution
        prepareTitle(); searchSubtitle = CommandSearch.normalize(subtitle); searchKeywords = keywords.map(CommandSearch.normalize)
    }
    private enum CodingKeys: String, CodingKey { case id, title, subtitle, keywords, kind, payload, objectRevision, contribution }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), title: try values.decode(String.self, forKey: .title),
            subtitle: try values.decode(String.self, forKey: .subtitle), keywords: try values.decode([String].self, forKey: .keywords),
            kind: try values.decode(CommandKind.self, forKey: .kind), payload: try values.decode(String.self, forKey: .payload),
            objectRevision: try values.decodeIfPresent(String.self, forKey: .objectRevision),
            contribution: try values.decodeIfPresent(CommandContributionBinding.self, forKey: .contribution))
    }
    public static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.title == right.title && left.subtitle == right.subtitle && left.keywords == right.keywords &&
        left.kind == right.kind && left.payload == right.payload && left.objectRevision == right.objectRevision && left.contribution == right.contribution
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(title); hasher.combine(subtitle); hasher.combine(keywords)
        hasher.combine(kind); hasher.combine(payload); hasher.combine(objectRevision); hasher.combine(contribution)
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
