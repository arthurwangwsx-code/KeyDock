import Foundation

/// 4MiB是新写入预算；16MiB有界加载窗口允许旧版本历史先展示/裁剪，超限保留原文件报错。
public struct InvocationRetentionPolicy: Equatable, Sendable {
    public var maxFinishedAge: TimeInterval
    public var maxFinishedCount: Int
    public var maxFileBytes: Int
    public var maxLoadBytes: Int
    public init(maxFinishedAge: TimeInterval = 90 * 86_400, maxFinishedCount: Int = 2_000,
                maxFileBytes: Int = 4 * 1_048_576, maxLoadBytes: Int = 16 * 1_048_576) {
        self.maxFinishedAge = maxFinishedAge; self.maxFinishedCount = maxFinishedCount
        self.maxFileBytes = maxFileBytes; self.maxLoadBytes = maxLoadBytes
    }
}

public enum InvocationCleanupFailure: Equatable, Sendable {
    case capacityExceeded, invalidClock
    case io(Int32)
    /// rename已发生但目录同步失败；逻辑内存跟随新文件，不能宣称删除已持久确认。
    case durabilityUncertain(Int32)
}

public struct InvocationCleanupReport: Equatable, Sendable {
    public let removedIDs: Set<UUID>
    public let failedIDs: Set<UUID>
    /// 与操作结果同时在actor内取得；宿主不需要再次await list来判断哪些候选仍存在。
    public let remainingIDs: Set<UUID>
    public let protectedIDs: Set<UUID>
    /// 数量和字节预算是否满足；被保护记录可暂时跨越终态年龄/数量阈值。
    public let limitsSatisfied: Bool
    public let failure: InvocationCleanupFailure?
}
