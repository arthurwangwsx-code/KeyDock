import Foundation

/// 父调用先封闭注册入口，再撤销已登记child。宿主仍须await每个真实worker后release。
public final class DesktopOperationGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var children: [ObjectIdentifier: DesktopOperationLease] = [:]
    public init() {}
    public var isCurrent: Bool { lock.withLock { !closed } }
    public var pendingChildCount: Int { lock.withLock { children.count } }
    public func check() throws { try Task.checkCancellation(); guard isCurrent else { throw CancellationError() } }
    public func makeChild() throws -> DesktopOperationLease {
        try lock.withLock {
            guard !closed, !Task.isCancelled else { throw CancellationError() }
            let lease = DesktopOperationLease(); children[ObjectIdentifier(lease)] = lease; return lease
        }
    }
    public func release(_ lease: DesktopOperationLease) {
        lock.withLock { lease.revoke(); children[ObjectIdentifier(lease)] = nil }
    }
    public func revoke() {
        lock.withLock { closed = true; for lease in children.values { lease.revoke() } }
    }
    deinit { revoke() }
}
