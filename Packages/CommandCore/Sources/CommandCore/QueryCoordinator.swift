import Foundation

public protocol CommandProviding: Sendable {
    /// 在同一查询内应唯一；重复 ID 仅采用第一个 Provider。
    var id: String { get }
    func commands(matching query: String) async throws -> [CommandItem]
}

public enum QueryFailure: String, Sendable, Equatable {
    case failed
    case timedOut
}

public struct QuerySnapshot: Sendable {
    public let generation: UInt64
    public let items: [CommandItem]
    public let pendingProviderIDs: Set<String>
    public let failures: [String: QueryFailure]
    public var isComplete: Bool { pendingProviderIDs.isEmpty }
}

/// 单个窗口的查询会话；不同窗口应各自持有一个实例。
public actor QueryCoordinator {
    private struct ActiveQuery {
        let generation: UInt64
        let query: String
        let preferences: CommandPreferences
        let providerIDs: [String]
        let continuation: AsyncStream<QuerySnapshot>.Continuation
        var pending: Set<String>
        var results: [String: [CommandItem]] = [:]
        var failures: [String: QueryFailure] = [:]
        var workers: [String: Task<Void, Never>] = [:]
        var deadlines: [String: Task<Void, Never>] = [:]
    }

    private var generation: UInt64 = 0
    private var active: ActiveQuery?

    public init() {}

    /// 新查询立即结束旧 stream，不等待不响应取消的 Provider。
    public func search(
        query: String,
        providers: [any CommandProviding],
        preferences: CommandPreferences = CommandPreferences(),
        timeout: Duration = .seconds(2)
    ) -> AsyncStream<QuerySnapshot> {
        endActive()
        generation &+= 1
        let currentGeneration = generation
        let pair = AsyncStream<QuerySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var seen = Set<String>()
        let uniqueProviders = providers.filter { seen.insert($0.id).inserted }
        let ids = uniqueProviders.map(\.id)
        active = ActiveQuery(
            generation: currentGeneration,
            query: query,
            preferences: preferences,
            providerIDs: ids,
            continuation: pair.continuation,
            pending: Set(ids)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(generation: currentGeneration) }
        }
        publish()

        for provider in uniqueProviders {
            let providerID = provider.id
            let worker = Task { [weak self] in
                do {
                    let items = try await provider.commands(matching: query)
                    guard !Task.isCancelled else { return }
                    await self?.receive(
                        providerID: providerID,
                        generation: currentGeneration,
                        items: items,
                        failure: nil
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.receive(
                        providerID: providerID,
                        generation: currentGeneration,
                        items: [],
                        failure: .failed
                    )
                }
            }
            let deadline = Task { [weak self] in
                do {
                    try await Task.sleep(for: max(timeout, .zero))
                    await self?.receive(
                        providerID: providerID,
                        generation: currentGeneration,
                        items: [],
                        failure: .timedOut
                    )
                } catch {
                    // 新查询、完成或取消都会终止该定时任务。
                }
            }
            active?.workers[providerID] = worker
            active?.deadlines[providerID] = deadline
        }
        return pair.stream
    }

    public func cancel() {
        endActive()
    }

    private func cancel(generation: UInt64) {
        guard active?.generation == generation else { return }
        endActive()
    }

    private func receive(
        providerID: String,
        generation: UInt64,
        items: [CommandItem],
        failure: QueryFailure?
    ) {
        guard active?.generation == generation,
              active?.pending.remove(providerID) != nil else { return }
        active?.workers.removeValue(forKey: providerID)?.cancel()
        active?.deadlines.removeValue(forKey: providerID)?.cancel()
        if let failure {
            active?.failures[providerID] = failure
        } else {
            active?.results[providerID] = items
        }
        publish()
    }

    private func publish() {
        guard let current = active else { return }
        // 按注册顺序合并，Provider 完成次序不改变同 ID 的权威来源。
        let items = current.providerIDs.flatMap { current.results[$0] ?? [] }
        current.continuation.yield(QuerySnapshot(
            generation: current.generation,
            items: CommandSearch.rank(query: current.query, items: items, preferences: current.preferences),
            pendingProviderIDs: current.pending,
            failures: current.failures
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
