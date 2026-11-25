import Foundation

/// 只公开内容代次；主线程发布前同步核验，避免跨actor二次await留下过期发布窗口。
final class AIUsageRevisionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var current: UInt64 { lock.withLock { value } }
    @discardableResult func advance() -> UInt64 { lock.withLock { value &+= 1; return value } }
}
