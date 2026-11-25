import Foundation

public enum CommandSearch {
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")
    /// 纯排序不依赖当前时钟；相同输入始终得到相同结果。
    public static func rank(
        query: String,
        items: [CommandItem],
        preferences: CommandPreferences
    ) -> [CommandItem] {
        let normalizedQuery = normalize(query)
        let tokens = normalizedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var seen = Set<String>()
        var matches: [Match] = []

        for item in items {
            // 同 ID 的第一个来源为权威来源，避免到达次序改变同一对象的载荷。
            guard seen.insert(item.id).inserted else { continue }
            let title = item.searchTitle
            let alias = normalize(preferences.aliases[item.id] ?? "")
            guard let score = score(
                query: normalizedQuery,
                tokens: tokens,
                title: title,
                titleWords: item.searchTitleWords,
                alias: alias,
                keywords: item.searchKeywords,
                subtitle: item.searchSubtitle
            ) else { continue }
            matches.append(Match(
                item: item,
                score: score + (preferences.favorites.contains(item.id) ? 150 : 0),
                recent: preferences.recent[item.id],
                normalizedTitle: title
            ))
        }

        return matches.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            switch (left.recent, right.recent) {
            case let (.some(a), .some(b)) where a != b:
                return a > b
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
            if left.normalizedTitle != right.normalizedTitle {
                return left.normalizedTitle < right.normalizedTitle
            }
            return left.item.id < right.item.id
        }.map(\.item)
    }

    private struct Match {
        var item: CommandItem
        var score: Int
        var recent: Date?
        var normalizedTitle: String
    }

    static func normalize(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        return value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: normalizationLocale
        ).lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func score(
        query: String,
        tokens: [String],
        title: String,
        titleWords: [Substring],
        alias: String,
        keywords: [String],
        subtitle: String
    ) -> Int? {
        guard !tokens.isEmpty else { return 0 }
        var score = 0
        for token in tokens {
            var best = 0
            if !alias.isEmpty {
                if alias == token { best = max(best, 1_300) }
                else if alias.hasPrefix(token) { best = max(best, 1_050) }
                else if alias.contains(token) { best = max(best, 700) }
            }
            if title == token { best = max(best, 1_200) }
            else if title.hasPrefix(token) { best = max(best, 1_000) }
            else if titleWords.contains(where: { $0.hasPrefix(token) }) {
                best = max(best, 850)
            } else if title.contains(token) { best = max(best, 650) }
            if keywords.contains(token) { best = max(best, 600) }
            else if keywords.contains(where: { $0.hasPrefix(token) }) { best = max(best, 500) }
            else if keywords.contains(where: { $0.contains(token) }) { best = max(best, 350) }
            if subtitle.contains(token) { best = max(best, 200) }
            // 收藏与最近使用只能调整匹配结果的顺序，不能让无关项进入结果。
            guard best > 0 else { return nil }
            score += best
        }
        if !alias.isEmpty && alias == query { score += 12_000 }
        else if title == query { score += 10_000 }
        else if !alias.isEmpty && alias.hasPrefix(query) { score += 4_000 }
        else if title.hasPrefix(query) { score += 3_000 }
        return score
    }
}
