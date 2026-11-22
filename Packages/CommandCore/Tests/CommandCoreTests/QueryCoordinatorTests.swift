import Foundation
import Testing
import CommandCore

private actor TestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private struct FixtureProvider: CommandProviding {
    let id: String
    let items: [CommandItem]
    var gate: TestGate?

    func commands(matching query: String) async throws -> [CommandItem] {
        if let gate { await gate.wait() }
        return items
    }
}

@Suite("异步查询隔离")
struct QueryCoordinatorTests {
    @Test("慢 Provider 不阻塞快速结果", .timeLimit(.minutes(1)))
    func partialResultsDoNotWaitForSlowProvider() async {
        let gate = TestGate()
        let coordinator = QueryCoordinator()
        let fast = CommandItem(id: "fast.item", title: "Fast", kind: .utility)
        let slow = CommandItem(id: "slow.item", title: "Slow", kind: .utility)
        let stream = await coordinator.search(query: "", providers: [
            FixtureProvider(id: "slow", items: [slow], gate: gate),
            FixtureProvider(id: "fast", items: [fast])
        ], timeout: .seconds(30))
        var firstResult: QuerySnapshot?
        for await snapshot in stream where !snapshot.items.isEmpty {
            firstResult = snapshot
            break
        }
        #expect(firstResult?.items == [fast])
        #expect(firstResult?.pendingProviderIDs == ["slow"])
        #expect(firstResult?.isComplete == false)
        await coordinator.cancel()
        await gate.open()
    }

    @Test("新查询结束旧流且迟到结果不能覆盖", .timeLimit(.minutes(1)))
    func staleQueryIsRetired() async {
        let gate = TestGate()
        let coordinator = QueryCoordinator()
        let old = await coordinator.search(query: "old", providers: [
            FixtureProvider(id: "old", items: [.init(id: "old", title: "Old", kind: .utility)], gate: gate)
        ])
        let current = await coordinator.search(query: "new", providers: [
            FixtureProvider(id: "new", items: [.init(id: "new", title: "New", kind: .utility)])
        ])
        await gate.open()
        var final: QuerySnapshot?
        for await snapshot in current { final = snapshot }
        var retiredItems: [CommandItem] = []
        for await snapshot in old { retiredItems += snapshot.items }
        #expect(final?.generation == 2)
        #expect(final?.items.map(\.id) == ["new"])
        #expect(final?.isComplete == true)
        #expect(retiredItems.isEmpty)
    }

    @Test("超时会终结查询，不等待忽略取消的 Provider", .timeLimit(.minutes(1)))
    func nonCooperativeProviderTimesOut() async {
        let gate = TestGate()
        let coordinator = QueryCoordinator()
        let stream = await coordinator.search(query: "", providers: [
            FixtureProvider(id: "blocked", items: [], gate: gate)
        ], timeout: .milliseconds(10))
        var final: QuerySnapshot?
        for await snapshot in stream { final = snapshot }
        #expect(final?.failures["blocked"] == .timedOut)
        #expect(final?.isComplete == true)
        await gate.open()
    }

    @Test("最终合并不依赖 Provider 完成顺序", .timeLimit(.minutes(1)))
    func registrationOrderOwnsDuplicateIdentity() async {
        let gate = TestGate()
        let coordinator = QueryCoordinator()
        let first = CommandItem(id: "same", title: "Tool", kind: .utility, payload: "first")
        let second = CommandItem(id: "same", title: "Tool", kind: .utility, payload: "second")
        let stream = await coordinator.search(query: "tool", providers: [
            FixtureProvider(id: "first", items: [first], gate: gate),
            FixtureProvider(id: "second", items: [second])
        ])
        var final: QuerySnapshot?
        for await snapshot in stream {
            if snapshot.pendingProviderIDs == ["first"] { await gate.open() }
            final = snapshot
        }
        #expect(final?.items == [first])
    }
}
