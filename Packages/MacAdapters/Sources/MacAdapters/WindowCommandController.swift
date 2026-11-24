import AppKit
@preconcurrency import ApplicationServices
import CommandCore

public enum WindowCommandError: Error { case busy, unavailable, changed, unsupported, unconfirmed }

/// 主线程只排队和激活；AX消息在独立actor执行，不读取窗口标题或控件正文。
@MainActor public final class WindowCommandController {
    private let worker = WindowCommandWorker()
    private var queue: [UUID] = []
    private var closed = false
    public init() {}
    public func close() { closed = true }
    public func perform(_ command: WindowCommand, identity: TargetIdentity, target: DesktopWindowTarget?, lease: DesktopOperationLease) async throws -> DesktopControlOutcome {
        try lease.begin()
        guard !closed, queue.count < 8 else { throw WindowCommandError.busy }
        let token = UUID(); queue.append(token)
        defer { queue.removeAll { $0 == token } }
        while queue.first != token {
            try lease.check(); guard !closed else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(15))
        }
        try lease.check(); guard !closed else { throw CancellationError() }
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        try await DesktopApplicationFocus.activate(identity, lease: lease)
        return try await worker.perform(command, identity: identity, target: target, lease: lease)
    }
}

enum DesktopApplicationFocus {
    @MainActor static func activate(_ identity: TargetIdentity, lease: DesktopOperationLease) async throws {
        try lease.check()
        guard let date = identity.launchDate, let app = NSRunningApplication(processIdentifier: identity.pid),
              !app.isTerminated, app.launchDate == date else { throw DesktopError.targetExpired }
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if current != identity.pid {
            guard current == ProcessInfo.processInfo.processIdentifier else { throw WindowCommandError.changed }
            try lease.markSubmission()
            guard app.activate() else { throw WindowCommandError.unconfirmed }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while !app.isActive, ContinuousClock.now < deadline {
                try lease.check(); try await Task.sleep(for: .milliseconds(20))
            }
        }
        try lease.check()
        guard app.isActive, !app.isTerminated, app.launchDate == date else { throw WindowCommandError.changed }
    }
}

private actor WindowCommandWorker {
    private var identity: TargetIdentity?
    private var references: [(String, AXUIElement)] = []
    private var ring = WindowCycleRing()
    func perform(_ command: WindowCommand, identity: TargetIdentity, target: DesktopWindowTarget?, lease: DesktopOperationLease) async throws -> DesktopControlOutcome {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        try validate(identity, lease: lease)
        if self.identity?.pid != identity.pid || self.identity?.launchDate != identity.launchDate {
            self.identity = identity; references = []; ring.reset()
        }
        let ax = AX.application(identity.pid)
        let windows = try AX.boundedWindows(ax)
        guard let focus = AX.element(ax, kAXFocusedWindowAttribute), windows.contains(where: { CFEqual($0, focus) }) else { throw WindowCommandError.unavailable }
        references = windows.map { element in
            (references.first(where: { CFEqual($0.1, element) })?.0 ?? UUID().uuidString, element)
        }
        guard let focusedID = references.first(where: { CFEqual($0.1, focus) })?.0 else { throw WindowCommandError.unavailable }
        if command == .minimize {
            guard let target, target.identity.pid == identity.pid, target.identity.launchDate == identity.launchDate,
                  CFEqual(target.reference.element, focus) else { throw WindowCommandError.changed }
            if AX.read(focus, kAXMinimizedAttribute) as? Bool == true { return .noOp }
            var writable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(focus, kAXMinimizedAttribute as CFString, &writable) == .success, writable.boolValue else { throw WindowCommandError.unsupported }
            try validate(identity, lease: lease)
            guard ContinuousClock.now < deadline else { throw WindowCommandError.unavailable }
            guard AX.equal(focus, AX.element(ax, kAXFocusedWindowAttribute)) else { throw WindowCommandError.changed }
            try lease.markSubmission()
            guard AXUIElementSetAttributeValue(focus, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else { throw WindowCommandError.unsupported }
            return try await readback(identity, lease: lease) { AX.read(focus, kAXMinimizedAttribute) as? Bool == true }
        }
        guard let move = ring.prepare(direction: command == .focusNext ? .next : .previous, windowIDs: references.map(\.0), focusedID: focusedID),
              let destination = references.first(where: { $0.0 == move.targetID })?.1 else { return .noOp }
        defer { ring.cancel(move) }
        try validate(identity, lease: lease)
        guard ring.isCurrent(move), AX.equal(focus, AX.element(ax, kAXFocusedWindowAttribute)),
              try AX.boundedWindowElements(ax).contains(where: { CFEqual($0, destination) }), ContinuousClock.now < deadline else { throw WindowCommandError.changed }
        try lease.markSubmission()
        guard AXUIElementPerformAction(destination, kAXRaiseAction as CFString) == .success else { throw WindowCommandError.unsupported }
        try validate(identity, lease: lease)
        _ = AXUIElementSetAttributeValue(ax, kAXFocusedWindowAttribute as CFString, destination)
        let result = try await readback(identity, lease: lease) { AX.equal(destination, AX.element(ax, kAXFocusedWindowAttribute)) }
        guard ring.commit(move, confirmedFocusedID: move.targetID) else { throw WindowCommandError.changed }
        return result
    }
    private func readback(_ identity: TargetIdentity, lease: DesktopOperationLease, matches: () -> Bool) async throws -> DesktopControlOutcome {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
        repeat {
            try validate(identity, lease: lease)
            if matches() { try lease.check(); return .confirmed }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        throw WindowCommandError.unconfirmed
    }
    private func validate(_ identity: TargetIdentity, lease: DesktopOperationLease) throws {
        try lease.check()
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        guard let date = identity.launchDate, let app = NSRunningApplication(processIdentifier: identity.pid),
              !app.isTerminated, app.launchDate == date, app.isActive else { throw WindowCommandError.changed }
    }
}

extension AX {
    /// 先取数量，再有界读取。无法取得完整可信快照时拒绝，不能把截断当作窗口关闭。
    static func boundedWindows(_ app: AXUIElement) throws -> [AXUIElement] {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
        let windows = try boundedWindowElements(app)
        var result: [AXUIElement] = []
        for window in windows {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw WindowCommandError.unavailable }
            if AX.string(window, kAXRoleAttribute) == kAXWindowRole && AX.read(window, kAXMinimizedAttribute) as? Bool != true { result.append(window) }
        }
        guard ContinuousClock.now < deadline else { throw WindowCommandError.unavailable }
        return result
    }
    static func boundedWindowElements(_ app: AXUIElement) throws -> [AXUIElement] {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count) == .success,
              count >= 0, count <= WindowCycleRing.maximumWindowCount else { throw WindowCommandError.unavailable }
        var array: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, count, &array) == .success,
              let values = array as? [AnyObject], values.count == count else { throw WindowCommandError.unavailable }
        var result: [AXUIElement] = []
        for value in values {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw WindowCommandError.unavailable }
            result.append(AX.bounded(value as! AXUIElement))
        }
        return result
    }
}
