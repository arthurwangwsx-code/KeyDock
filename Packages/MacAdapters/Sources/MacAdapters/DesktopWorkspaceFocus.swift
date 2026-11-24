import AppKit
@preconcurrency import ApplicationServices

/// 只许可已确认源→当前目标的一次交接；目标出现后旧源也不再放行。
public final class DesktopWorkspaceFocusFence: @unchecked Sendable {
    struct Handoff: Sendable { let id: UUID; let target: TargetIdentity }
    private let lock = NSLock()
    public let operations: DesktopOperationGroup
    private var source: TargetIdentity
    private var handoff: Handoff?
    private var observedTarget = false
    private var revoked = false
    public init(source: TargetIdentity, operations: DesktopOperationGroup) throws {
        guard source.pid > 0, source.launchDate != nil else { throw WindowCommandError.changed }
        self.source = source; self.operations = operations
    }
    static func sameProcess(_ lhs: TargetIdentity?, _ rhs: TargetIdentity?) -> Bool {
        guard let lhs, let rhs, lhs.launchDate != nil, rhs.launchDate != nil else { return false }
        return lhs.pid == rhs.pid && lhs.launchDate == rhs.launchDate
    }
    public func revoke() { lock.withLock { revoked = true }; operations.revoke() }
    public func check() throws {
        try operations.check()
        guard lock.withLock({ !revoked }), !Task.isCancelled else { throw CancellationError() }
    }
    public func observe(_ identity: TargetIdentity?) {
        let invalid = lock.withLock {
            guard !revoked else { return true }
            if let handoff {
                if Self.sameProcess(identity, handoff.target) { observedTarget = true; return false }
                if !observedTarget && Self.sameProcess(identity, source) { return false }
            } else if Self.sameProcess(identity, source) { return false }
            revoked = true; return true
        }
        if invalid { operations.revoke() }
    }
    func begin(to target: TargetIdentity) throws -> Handoff {
        try check()
        return try lock.withLock {
            guard !revoked, handoff == nil, target.pid > 0, target.launchDate != nil else { throw WindowCommandError.changed }
            let next = Handoff(id: UUID(), target: target)
            handoff = next; observedTarget = Self.sameProcess(source, target); return next
        }
    }
    func complete(_ token: Handoff, actual: TargetIdentity?) throws {
        try check()
        try lock.withLock {
            guard !revoked, handoff?.id == token.id, observedTarget, Self.sameProcess(actual, token.target) else { throw WindowCommandError.changed }
            source = token.target; handoff = nil; observedTarget = false
        }
    }
}

/// 整个批次持有它，避免两次focus之间漏掉第三方抢焦点后又切回的事件。
@MainActor public final class DesktopWorkspaceFocusSession {
    public let fence: DesktopWorkspaceFocusFence
    private let observation: WorkspaceActivationObservation
    public init(source: TargetIdentity, operations: DesktopOperationGroup) throws {
        let fence = try DesktopWorkspaceFocusFence(source: source, operations: operations)
        self.fence = fence; observation = WorkspaceActivationObservation(fence: fence)
        fence.observe(WorkspaceWindowFocusController.foregroundIdentity())
        try fence.check()
    }
    public func close() { fence.revoke(); observation.close() }
    deinit { fence.revoke() }
}

private final class WorkspaceActivationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    init(fence: DesktopWorkspaceFocusFence) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { fence.observe(nil); return }
            fence.observe(.init(pid: app.processIdentifier, launchDate: app.launchDate, name: ""))
        }
    }
    func close() {
        let token = lock.withLock { let token = observer; observer = nil; return token }
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
    deinit { close() }
}

@MainActor struct WorkspaceWindowFocusEnvironment {
    var foreground: () -> TargetIdentity?
    var validate: (DesktopWindowTarget) async throws -> Void
    var activate: (DesktopWindowTarget) -> Bool
    var raiseAndFocus: (DesktopWindowTarget, DesktopOperationLease, DesktopWorkspaceFocusFence) async throws -> Void
    var isFocused: (DesktopWindowTarget, DesktopOperationLease, DesktopWorkspaceFocusFence) async throws -> Bool
}

/// 不放宽原单窗口DesktopApplicationFocus的全局guard。
@MainActor public final class WorkspaceWindowFocusController {
    private let environment: WorkspaceWindowFocusEnvironment
    public convenience init() {
        self.init(environment: .init(foreground: { Self.foregroundIdentity() }, validate: { target in
            let task = Task.detached { try Self.validateMembership(target) }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }, activate: { NSRunningApplication(processIdentifier: $0.identity.pid)?.activate() == true }, raiseAndFocus: { target, lease, fence in
            try await Self.worker(lease: lease, fence: fence) {
                try Self.validate(target, lease: lease, fence: fence)
                try lease.markSubmission()
                guard AXUIElementPerformAction(target.reference.element, kAXRaiseAction as CFString) == .success else { throw WindowCommandError.unsupported }
                try Self.validate(target, lease: lease, fence: fence)
                // setter可不受支持；是否成功始终由下一步CFEqual读回判断。
                _ = AXUIElementSetAttributeValue(AX.application(target.identity.pid), kAXFocusedWindowAttribute as CFString, target.reference.element)
                try lease.check(); try fence.check()
            }
        }, isFocused: { target, lease, fence in
            try await Self.worker(lease: lease, fence: fence) {
                try Self.validate(target, lease: lease, fence: fence)
                return AX.equal(target.reference.element, AX.element(AX.application(target.identity.pid), kAXFocusedWindowAttribute))
            }
        }))
    }
    init(environment: WorkspaceWindowFocusEnvironment) { self.environment = environment }
    public func focus(_ target: DesktopWindowTarget, fence: DesktopWorkspaceFocusFence, lease: DesktopOperationLease,
                      timeout: Duration = .milliseconds(500)) async throws {
        try await withTaskCancellationHandler {
            do { try lease.begin() } catch { fence.revoke(); lease.revoke(); throw error }
            try await perform(target, fence: fence, lease: lease, timeout: timeout)
        } onCancel: { fence.revoke(); lease.revoke() }
    }
    private func perform(_ target: DesktopWindowTarget, fence: DesktopWorkspaceFocusFence, lease: DesktopOperationLease, timeout: Duration) async throws {
        do {
            try await environment.validate(target)
            try check(fence, lease: lease)
            // 只读等待期间仍holding原source；确认后才在同一片段内开放本次交接。
            let token = try fence.begin(to: target.identity)
            try check(fence, lease: lease)
            if !DesktopWorkspaceFocusFence.sameProcess(environment.foreground(), target.identity) {
                try lease.markSubmission(operation: .activate)
                guard environment.activate(target) else { throw WindowCommandError.unconfirmed }
            }
            let deadline = ContinuousClock.now.advanced(by: min(.seconds(2), max(.milliseconds(1), timeout)))
            while !DesktopWorkspaceFocusFence.sameProcess(environment.foreground(), target.identity) {
                try check(fence, lease: lease)
                guard ContinuousClock.now < deadline else { throw WindowCommandError.unconfirmed }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(fence, lease: lease)
            try await environment.raiseAndFocus(target, lease, fence)
            try check(fence, lease: lease)
            let readbackDeadline = ContinuousClock.now.advanced(by: min(.milliseconds(400), max(.milliseconds(1), timeout)))
            repeat {
                try check(fence, lease: lease)
                let confirmed = try await environment.isFocused(target, lease, fence)
                try check(fence, lease: lease)
                if confirmed {
                    // isFocused已验证原对象；最终CFEqual之后不再插入异步membership等待。
                    try fence.complete(token, actual: environment.foreground()); return
                }
                guard ContinuousClock.now < readbackDeadline else { throw WindowCommandError.unconfirmed }
                try await Task.sleep(for: .milliseconds(20))
            } while true
        } catch { fence.revoke(); lease.revoke(); throw error }
    }
    private func check(_ fence: DesktopWorkspaceFocusFence, lease: DesktopOperationLease) throws {
        try Task.checkCancellation(); try lease.check(); fence.observe(environment.foreground()); try fence.check()
    }
    static func foregroundIdentity() -> TargetIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return .init(pid: app.processIdentifier, launchDate: app.launchDate, name: "")
    }
    nonisolated private static func validate(_ target: DesktopWindowTarget, lease: DesktopOperationLease, fence: DesktopWorkspaceFocusFence) throws {
        try lease.check(); try fence.check()
        try validateMembership(target)
        guard NSRunningApplication(processIdentifier: target.identity.pid)?.isActive == true else { throw WindowCommandError.changed }
        try lease.check(); try fence.check()
    }
    nonisolated private static func validateMembership(_ target: DesktopWindowTarget) throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        guard let app = NSRunningApplication(processIdentifier: target.identity.pid), let date = target.identity.launchDate,
              !app.isTerminated, app.launchDate == date,
              try AX.boundedWindowElements(AX.application(target.identity.pid)).contains(where: { CFEqual($0, target.reference.element) }) else { throw WindowCommandError.changed }
        try Task.checkCancellation()
    }
    private static func worker<T: Sendable>(lease: DesktopOperationLease, fence: DesktopWorkspaceFocusFence, body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try body() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { fence.revoke(); lease.revoke(); task.cancel() }
    }
}
