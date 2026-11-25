import Foundation
import Testing
import CommandCore

@Suite("命令检索")
struct CommandSearchTests {
    @Test("别名精确匹配优先，收藏不引入无关对象")
    func aliasAndFiltering() {
        let terminal = CommandItem(id: "app.terminal", title: "Terminal", kind: .application)
        let editor = CommandItem(id: "app.editor", title: "Visual Studio Code", kind: .application)
        let unrelated = CommandItem(id: "app.other", title: "Photos", kind: .application)
        let preferences = CommandPreferences(
            aliases: [editor.id: "term"],
            favorites: [unrelated.id],
            recent: [unrelated.id: Date()]
        )
        let result = CommandSearch.rank(query: "term", items: [terminal, unrelated, editor], preferences: preferences)
        #expect(result.map(\.id) == [editor.id, terminal.id])
    }

    @Test("多个词必须全部匹配，中英文与宽字符不敏感")
    func tokenAndUnicodeMatching() {
        let item = CommandItem(
            id: "command.cafe", title: "Café 终端", subtitle: "workspace", keywords: ["项目"], kind: .command
        )
        #expect(CommandSearch.rank(query: "ＣＡＦＥ 项目", items: [item], preferences: .init()) == [item])
        #expect(CommandSearch.rank(query: "终端 missing", items: [item], preferences: .init()).isEmpty)
    }

    @Test("重复 ID 仅保留首个权威载荷，平分结果稳定")
    func duplicateIdentityAndTies() {
        let first = CommandItem(id: "a", title: "Tool", kind: .utility, payload: "first")
        let duplicate = CommandItem(id: "a", title: "Tool", kind: .utility, payload: "second")
        let other = CommandItem(id: "b", title: "Tool", kind: .utility)
        let result = CommandSearch.rank(query: "tool", items: [other, first, duplicate], preferences: .init())
        #expect(result.map(\.id) == ["a", "b"])
        #expect(result.first?.payload == "first")
    }

    @Test("空查询按收藏和最近使用排序，不依赖调用时钟")
    func emptyQueryPreferences() {
        let a = CommandItem(id: "a", title: "A", kind: .utility)
        let b = CommandItem(id: "b", title: "B", kind: .utility)
        let c = CommandItem(id: "c", title: "C", kind: .utility)
        let preferences = CommandPreferences(favorites: [c.id], recent: [b.id: Date(timeIntervalSince1970: 100)])
        #expect(CommandSearch.rank(query: "  ", items: [a, b, c], preferences: preferences).map(\.id) == ["c", "b", "a"])
    }

    @Test("旧JSON解码会建立派生索引，编码不加入缓存字段")
    func decodedLegacyItemsKeepSearchAndWireContracts() throws {
        let bytes = Data(#"{"id":"legacy","title":"Ｃafé  终端","subtitle":"Synthetic workspace","keywords":["项目"],"kind":"command","payload":"synthetic"}"#.utf8)
        let item = try JSONDecoder().decode(CommandItem.self, from: bytes)
        #expect(CommandSearch.rank(query: "cafe 项目", items: [item], preferences: .init()) == [item])
        #expect(item.preparedSearchTextUTF8Bytes > 0)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(Set(encoded.keys) == ["id", "title", "subtitle", "keywords", "kind", "payload"])
        var missing = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); missing["payload"] = nil
        let invalid = try JSONSerialization.data(withJSONObject: missing)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CommandItem.self, from: invalid) }
    }

    @Test("文本与数组inout写回更新自身缓存，不污染原值快照")
    func editsAndArrayWritebackInvalidateOnlyTheirOwnPreparedText() {
        let original = CommandItem(id: "same", title: "Alpha Terminal", subtitle: "oldsubtitle", keywords: ["oldkeyword"], kind: .utility)
        var edited = original
        edited.title = "Ｇamma  终端"; edited.subtitle = "newsubtitle"; edited.keywords[0] = "newkeyword"
        edited.keywords.append("追加")
        for query in ["Alpha", "oldsubtitle", "oldkeyword"] {
            #expect(CommandSearch.rank(query: query, items: [edited], preferences: .init()).isEmpty)
            #expect(CommandSearch.rank(query: query, items: [original], preferences: .init()) == [original])
        }
        for query in ["gamma 终端", "newsubtitle", "newkeyword", "追加"] {
            #expect(CommandSearch.rank(query: query, items: [edited], preferences: .init()) == [edited])
        }
        edited.keywords.removeAll()
        #expect(CommandSearch.rank(query: "newkeyword", items: [edited], preferences: .init()).isEmpty)
        edited.title.append(" Extra")
        #expect(CommandSearch.rank(query: "extra", items: [edited], preferences: .init()) == [edited])
    }

    @Test("偏好实时应用，首个重复ID不继承另一个对象的缓存")
    func preferencesRemainLiveAndDuplicatesNeverSharePreparedFields() {
        let first = CommandItem(id: "duplicate", title: "Authoritative", kind: .utility)
        let duplicate = CommandItem(id: "duplicate", title: "Fresh match", kind: .utility)
        #expect(CommandSearch.rank(query: "Fresh", items: [first, duplicate], preferences: .init()).isEmpty)
        var preferences = CommandPreferences(aliases: [first.id: "Fresh"])
        #expect(CommandSearch.rank(query: "Fresh", items: [first], preferences: preferences) == [first])
        preferences.aliases.removeAll(); preferences.favorites = [first.id]
        #expect(CommandSearch.rank(query: "Fresh", items: [first], preferences: preferences).isEmpty)
        let other = CommandItem(id: "other", title: "Authoritative", kind: .utility)
        preferences.favorites = [other.id]
        #expect(CommandSearch.rank(query: "author", items: [first, other], preferences: preferences).first == other)
        preferences.favorites.removeAll(); preferences.recent[first.id] = Date(timeIntervalSince1970: 1)
        #expect(CommandSearch.rank(query: "author", items: [other, first], preferences: preferences).first == first)
    }

    @Test("缓存准备历史不改变公开相等哈希和编码")
    func derivedPreparationIsExcludedFromEqualityAndHash() throws {
        let original = CommandItem(id: "same", title: "Café", subtitle: "Text", keywords: ["项目"], kind: .utility, payload: "payload", objectRevision: "revision")
        var edited = CommandItem(id: "same", title: "Temporary", kind: .utility)
        edited.title = original.title; edited.subtitle = original.subtitle; edited.keywords.append("项目")
        edited.payload = "payload"; edited.objectRevision = "revision"
        #expect(edited == original && Set([original, edited]).count == 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(edited) == encoder.encode(original))
        let decoded = try JSONDecoder().decode(CommandItem.self, from: encoder.encode(original))
        #expect(decoded == original && Set([decoded, original]).count == 1)
    }
}
