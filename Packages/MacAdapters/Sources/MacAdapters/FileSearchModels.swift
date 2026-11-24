import Foundation

public struct FileSearchLimits: Sendable, Equatable {
    public let maxScannedItems: Int
    public let maxDepth: Int
    public init(maxScannedItems: Int = 10_000, maxDepth: Int = 12) {
        self.maxScannedItems = maxScannedItems; self.maxDepth = maxDepth
    }
}
public enum FileSearchError: Error, Sendable, Equatable {
    case invalidLimits, invalidLimit, invalidQuery, invalidRoots
    case staleResult, scopeChanged, pathChanged, targetChanged, notRegularFile
}
public enum FileSearchScopeStatus: String, Sendable, Equatable {
    case available, partiallyUnavailable, unavailable, symbolicLinkExcluded, packageExcluded, notDirectory, changed, notScanned
}
public enum FileSearchTruncationReason: String, Sendable, Hashable {
    case scannedItemLimit, depthLimit, resultLimit
}
public struct FileSearchScopeSummary: Sendable, Equatable {
    public let requestedURL: URL
    public let resolvedURL: URL?
    public let status: FileSearchScopeStatus
    public let scannedItems: Int
    public let inaccessibleItems: Int
}
/// 只在内存中引用当前搜索快照，不可由外部JSON解码或持久化成授权。
public struct FileSearchResult: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let url: URL
    public let objectRevision: String
    let queryToken: UUID
    let scope: FileSearchRootIdentity
    let relativeComponents: [String]
    let directoryChain: [FileSearchDirectoryIdentity]
    let identity: FileSearchObjectIdentity
}
public struct FileSearchReport: Sendable, Equatable {
    public let requestID: UUID
    public let results: [FileSearchResult]
    public let scopes: [FileSearchScopeSummary]
    public let scannedItems: Int
    public let truncationReasons: Set<FileSearchTruncationReason>
    public var isTruncated: Bool { !truncationReasons.isEmpty }
    public var isPartial: Bool { isTruncated || scopes.contains { $0.status != .available && $0.status != .packageExcluded } }
    /// 静态产品边界；“未截断”不表示搜索隐藏项／包内容／符号链接目标或文件正文。
    public let skipsHiddenItems = true
    public let skipsPackages = true
    public let skipsSymbolicLinks = true
    public let searchesFileContents = false
}
