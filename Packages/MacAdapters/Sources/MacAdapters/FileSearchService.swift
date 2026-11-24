import Foundation
import Darwin

/// 搜索只发生在显式传入的目录，结果只能交给“在Finder显示”入口，不承担执行／打开能力。
public actor FileSearchService {
    private let limits: FileSearchLimits
    private let beforeWorkerReturns: (@Sendable (String) -> Void)?
    private var generation = UUID()
    private var worker: Task<FileSearchReport, any Error>?
    private var cached: FileSearchReport?

    public init(limits: FileSearchLimits = .init()) throws {
        try Self.check(limits)
        self.limits = limits; beforeWorkerReturns = nil
    }
    /// 只供@testable确定性复现迟到worker；生产默认没有阻塞钩子。
    init(limits: FileSearchLimits = .init(), beforeWorkerReturns: @escaping @Sendable (String) -> Void) throws {
        try Self.check(limits)
        self.limits = limits; self.beforeWorkerReturns = beforeWorkerReturns
    }
    public func currentReport() -> FileSearchReport? { cached }
    public func cancel() {
        generation = UUID(); worker?.cancel(); worker = nil; cached = nil
    }
    public func search(query: String, roots: [URL], limit: Int = 50) async throws -> FileSearchReport {
        try Task.checkCancellation()
        worker?.cancel(); worker = nil; cached = nil
        let token = UUID(); generation = token
        guard (1...100).contains(limit) else { throw FileSearchError.invalidLimit }
        guard query.utf8.count <= 256, !query.utf8.contains(0) else { throw FileSearchError.invalidQuery }
        guard roots.count <= 8, roots.allSatisfy({ $0.isFileURL && (($0.host ?? "").isEmpty || $0.host == "localhost") && $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) }) else { throw FileSearchError.invalidRoots }
        let limits = limits, hook = beforeWorkerReturns
        let task = Task.detached(priority: .userInitiated) {
            let report = try FileSearchScanner(query: query, token: token, limits: limits, resultLimit: limit).run(roots: roots)
            hook?(query)
            return report
        }
        worker = task
        do {
            let report = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            cached = report; worker = nil
            return report
        } catch {
            if generation == token { worker = nil }
            throw error
        }
    }
    public func validate(_ result: FileSearchResult, allowedRoots: [URL]? = nil) throws -> URL {
        try Task.checkCancellation()
        guard let cached, cached.requestID == generation, result.queryToken == generation,
              cached.results.contains(result) else { throw FileSearchError.staleResult }
        if let allowedRoots {
            guard allowedRoots.contains(where:{ $0.standardizedFileURL == result.scope.requestedURL }) else { throw FileSearchError.scopeChanged }
            let (current, fd) = try FileSearchPOSIX.prepare(result.scope.requestedURL)
            Darwin.close(fd)
            guard current == result.scope else { throw FileSearchError.scopeChanged }
        }
        return try FileSearchPOSIX.validate(result)
    }
    private static func check(_ limits: FileSearchLimits) throws {
        guard (1...10_000).contains(limits.maxScannedItems), (0...12).contains(limits.maxDepth) else { throw FileSearchError.invalidLimits }
    }
    deinit { worker?.cancel() }
}
