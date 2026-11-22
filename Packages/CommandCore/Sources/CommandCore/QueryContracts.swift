import Foundation

public enum QueryMode: String, Sendable, CaseIterable {
    case all, applications, windows, savedCommands, clipboard, aiActions, utilities

    func includes(_ kind: CommandKind) -> Bool {
        switch self {
        case .all: true
        case .applications: kind == .application
        case .windows: kind == .window
        case .savedCommands: kind == .command
        case .clipboard: kind == .clipboard
        case .aiActions: kind == .ai
        case .utilities: kind == .utility
        }
    }
}

/// 单个查询会话内 generation 必须递增；queryID 标识一次具体请求。
/// 查询正文只在内存传递，不因使用此合同自动进入日志或持久化。
public struct QueryRequest: Sendable, Equatable {
    public let queryID: UUID
    public let generation: UInt64
    public let text: String
    public let mode: QueryMode
    public let source: String
    public let issuedAt: Date

    public init(
        queryID: UUID = UUID(), generation: UInt64, text: String,
        mode: QueryMode = .all, source: String = "keydock.command-search", issuedAt: Date = Date()
    ) {
        self.queryID = queryID; self.generation = generation; self.text = text
        self.mode = mode; self.source = source; self.issuedAt = issuedAt
    }
}

/// 每批 items 是当前已合并、去重、排序的完整快照，而不是仅一个来源的增量。
public struct ResultBatch: Sendable {
    public let request: QueryRequest
    /// 引发本批更新的 Provider；查询刚开始的初始批次为 nil。
    public let providerID: String?
    public let items: [CommandItem]
    public let pendingProviderIDs: Set<String>
    public let failures: [String: QueryFailure]
    public var queryID: UUID { request.queryID }
    public var generation: UInt64 { request.generation }
    public var isComplete: Bool { pendingProviderIDs.isEmpty }

    public init(
        request: QueryRequest, providerID: String? = nil, items: [CommandItem],
        pendingProviderIDs: Set<String>, failures: [String: QueryFailure] = [:]
    ) {
        self.request = request; self.providerID = providerID; self.items = items
        self.pendingProviderIDs = pendingProviderIDs; self.failures = failures
    }
}

/// 保留首版公开结果类型的源码兼容性，统一通过 ResultBatch 传递请求上下文。
public typealias QuerySnapshot = ResultBatch
