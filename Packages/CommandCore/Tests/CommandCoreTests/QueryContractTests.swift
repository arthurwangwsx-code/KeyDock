import Foundation
import Testing
import CommandCore

private actor QueryContractGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true; let values = waiters; waiters.removeAll()
        values.forEach { $0.resume() }
    }
}
private actor QueryRecorder {
    private var values: [String] = []
    func record(_ query: String) { values.append(query) }
    func recorded() -> [String] { values }
}
private struct QueryContractProvider: CommandProviding {
    let id: String
    let items: [CommandItem]
    var gate: QueryContractGate?
    var recorder: QueryRecorder?
    func commands(matching query: String) async throws -> [CommandItem] {
        await recorder?.record(query)
        if let gate { await gate.wait() }
        return items
    }
}

@Suite("查询请求与结果合同")
struct QueryContractTests {
    @Test("请求身份和模式进入实际 Provider 与排序结果", .timeLimit(.minutes(1)))
    func typedRequestControlsActualResults() async {
        let recorder = QueryRecorder(), coordinator = QueryCoordinator()
        let app = CommandItem(id: "app.tool", title: "Tool", kind: .application)
        let window = CommandItem(id: "window.tool", title: "Tool", kind: .window)
        let request = QueryRequest(generation: 7, text: "tool", mode: .windows,
                                   source: "keydock.test-window", issuedAt: Date(timeIntervalSince1970: 1234))
        let stream = await coordinator.search(request: request, providers: [QueryContractProvider(id: "fixture", items: [app, window], recorder: recorder)])
        var final: ResultBatch?
        for await batch in stream { final = batch }
        #expect(await recorder.recorded() == ["tool"])
        #expect(final?.request == request)
        #expect(final?.queryID == request.queryID && final?.generation == 7)
        #expect(final?.providerID == "fixture")
        #expect(final?.items == [window])
        #expect(final?.isComplete == true)
    }

    @Test("迟到旧请求不取消当前查询", .timeLimit(.minutes(1)))
    func delayedRequestCannotRetireNewerSearch() async {
        let coordinator = QueryCoordinator(), gate = QueryContractGate()
        let item = CommandItem(id: "new", title: "New", kind: .utility)
        let current = await coordinator.search(request: .init(generation: 20, text: "new"), providers: [QueryContractProvider(id: "blocked", items: [item], gate: gate)])
        let stale = await coordinator.search(request: .init(generation: 19, text: "old"), providers: [QueryContractProvider(id: "old", items: [])])
        var retired: ResultBatch?
        for await batch in stale { retired = batch }
        #expect(retired?.failures["keydock.query"] == .superseded)
        await gate.open()
        var final: ResultBatch?
        for await batch in current { final = batch }
        #expect(final?.generation == 20 && final?.items == [item])
    }

    @Test("兼容入口在同一会话继续递增身份", .timeLimit(.minutes(1)))
    func convenienceAPISharesTypedChain() async {
        let coordinator = QueryCoordinator()
        let typed = await coordinator.search(request: .init(generation: 9, text: "first"), providers: [])
        for await _ in typed {}
        let compatible = await coordinator.search(query: "second", providers: [])
        var final: QuerySnapshot?
        for await batch in compatible { final = batch }
        #expect(final?.generation == 10)
        #expect(final?.request.text == "second")
        #expect(final?.isComplete == true)
    }
}
