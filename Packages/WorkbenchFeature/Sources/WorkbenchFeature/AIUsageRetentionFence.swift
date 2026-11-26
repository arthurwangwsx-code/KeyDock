import Foundation

struct AIUsageRetentionRead: Sendable, Equatable {
    let epoch: UInt64
    let admitted: Bool
}

/// 跨actor维护等待期间也同步可见；回调到主线程不是删除围栏。
final class AIUsageRetentionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var active = false
    var current: AIUsageRetentionRead { lock.withLock { .init(epoch: epoch, admitted: !active) } }
    func begin() { lock.withLock { precondition(!active); epoch &+= 1; active = true } }
    func end() { lock.withLock { precondition(active); epoch &+= 1; active = false } }
    func accepts(_ read: AIUsageRetentionRead) -> Bool {
        lock.withLock { read.admitted && !active && read.epoch == epoch }
    }
}
