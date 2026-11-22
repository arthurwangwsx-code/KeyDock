import Foundation

public protocol CommandProviding: Sendable {
    /// 在同一查询内应唯一；重复 ID 仅采用第一个 Provider。
    var id: String { get }
    func commands(matching query: String) async throws -> [CommandItem]
}

public enum QueryFailure: String, Sendable, Equatable {
    case failed
    case timedOut
    case superseded
}

/// 单个窗口的查询会话；不同窗口应各自持有一个实例。
public actor QueryCoordinator {
    private struct ActiveQuery {
        let request: QueryRequest
        let preferences: CommandPreferences
        let providerIDs: [String]
        let continuation: AsyncStream<ResultBatch>.Continuation
        var pending: Set<String>
        var results: [String: [CommandItem]] = [:]
        var failures: [String: QueryFailure] = [:]
        var workers: [String: Task<Void, Never>] = [:]
        var deadlines: [String: Task<Void, Never>] = [:]
    }

    private var generation: UInt64 = 0
    private var active: ActiveQuery?

    public init() {}

    /// 原有便捷 API 也经过同一请求/结果链路，不另起排序实现。
    public func search(
        query: String,
        providers: [any CommandProviding],
        preferences: CommandPreferences = CommandPreferences(),
        timeout: Duration = .seconds(2)
    ) -> AsyncStream<QuerySnapshot> {
        let request = QueryRequest(generation: generation &+ 1, text: query)
        return search(request: request, providers: providers, preferences: preferences, timeout: timeout)
    }

    /// 调用方拥有递增 generation；迟到的旧启动任务不能取消较新的查询。
    public func search(
        request: QueryRequest,
        providers: [any CommandProviding],
        preferences: CommandPreferences = CommandPreferences(),
        timeout: Duration = .seconds(2)
    ) -> AsyncStream<ResultBatch> {
        guard request.generation > generation else {
            return AsyncStream { continuation in
                continuation.yield(ResultBatch(request: request, items: [], pendingProviderIDs: [], failures: ["keydock.query": .superseded]))
                continuation.finish()
            }
        }
        endActive()
        generation = request.generation
        let pair = AsyncStream<ResultBatch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var seen = Set<String>()
        let uniqueProviders = providers.filter { seen.insert($0.id).inserted }
        let ids = uniqueProviders.map(\.id)
        active = ActiveQuery(
            request: request, preferences: preferences, providerIDs: ids,
            continuation: pair.continuation, pending: Set(ids)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(queryID: request.queryID, generation: request.generation) }
        }
        publish(providerID: nil)

        for provider in uniqueProviders {
            let providerID = provider.id
            let worker = Task { [weak self] in
                do {
                    let items = try await provider.commands(matching: request.text)
                    guard !Task.isCancelled else { return }
                    await self?.receive(providerID: providerID, request: request, items: items, failure: nil)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.receive(providerID: providerID, request: request, items: [], failure: .failed)
                }
            }
            let deadline = Task { [weak self] in
                do {
                    try await Task.sleep(for: max(timeout, .zero))
                    await self?.receive(providerID: providerID, request: request, items: [], failure: .timedOut)
                } catch {
                    // 新查询、完成或取消都会终止该定时任务。
                }
            }
            active?.workers[providerID] = worker
            active?.deadlines[providerID] = deadline
        }
        return pair.stream
    }

    public func cancel() { endActive() }

    private func cancel(queryID: UUID, generation: UInt64) {
        guard active?.request.queryID == queryID, active?.request.generation == generation else { return }
        endActive()
    }

    private func receive(providerID: String, request: QueryRequest, items: [CommandItem], failure: QueryFailure?) {
        guard active?.request.queryID == request.queryID,
              active?.request.generation == request.generation,
              active?.pending.remove(providerID) != nil else { return }
        active?.workers.removeValue(forKey: providerID)?.cancel()
        active?.deadlines.removeValue(forKey: providerID)?.cancel()
        if let failure { active?.failures[providerID] = failure }
        else { active?.results[providerID] = items }
        publish(providerID: providerID)
    }

    private func publish(providerID: String?) {
        guard let current = active else { return }
        // 注册顺序决定重复 ID 的权威来源；mode 在实际结果链路过滤，不仅是展示标签。
        let items = current.providerIDs.flatMap { current.results[$0] ?? [] }.filter { current.request.mode.includes($0.kind) }
        current.continuation.yield(ResultBatch(
            request: current.request, providerID: providerID,
            items: CommandSearch.rank(query: current.request.text, items: items, preferences: current.preferences),
            pendingProviderIDs: current.pending, failures: current.failures
        ))
        if current.pending.isEmpty { endActive() }
    }

    private func endActive() {
        guard let current = active else { return }
        active = nil
        current.workers.values.forEach { $0.cancel() }
        current.deadlines.values.forEach { $0.cancel() }
        current.continuation.finish()
    }
}
