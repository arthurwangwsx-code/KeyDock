import Foundation

public enum DesktopOperationLeaseError: Error { case alreadyUsed }
public enum DesktopNativeOperation: String, Sendable { case launch, hide, unhide, activate, quit }
/// 跨AX worker共享的单次调用状态；取消先撤销授权，再等待真实worker收口。
public final class DesktopOperationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private var submitted = false
    private var claimed = false
    private var nativeOperation: DesktopNativeOperation?
    public init() {}
    public var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return !revoked }
    public var didSubmit: Bool { lock.lock(); defer { lock.unlock() }; return submitted }
    public var lastNativeOperation: DesktopNativeOperation? { lock.lock(); defer { lock.unlock() }; return nativeOperation }
    public func revoke() { lock.lock(); revoked = true; lock.unlock() }
    public func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !revoked, !Task.isCancelled else { throw CancellationError() }
        guard !claimed else { throw DesktopOperationLeaseError.alreadyUsed }
        claimed = true
    }
    public func check() throws {
        guard isCurrent, !Task.isCancelled else { throw CancellationError() }
    }
    /// 一个已批准的操作可含多个有序系统调用；每步仍须check，不能重新选择目标。
    public func markSubmission(operation: DesktopNativeOperation? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard claimed, !revoked, !Task.isCancelled else { throw CancellationError() }
        submitted = true
        if let operation { nativeOperation = operation }
    }
}
