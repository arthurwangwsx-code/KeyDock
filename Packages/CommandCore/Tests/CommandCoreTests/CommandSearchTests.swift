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
}
