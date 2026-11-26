import AppKit
@preconcurrency import ApplicationServices

/// 窗口命令的最小上下文；不读取选区、输入控件值或窗口标题。
public final class DesktopWindowTarget: @unchecked Sendable {
    public let identity: TargetIdentity
    let reference: WindowReference
    init(identity: TargetIdentity, element: AXUIElement) {
        self.identity = identity
        reference = WindowReference(pid: identity.pid, launchDate: identity.launchDate, element: element, appName: identity.name, title: "")
    }
    static func capture(_ identity: TargetIdentity) throws -> DesktopWindowTarget {
        try Task.checkCancellation()
        guard identity.launchDate != nil, let app = NSRunningApplication(processIdentifier: identity.pid),
              !app.isTerminated, app.launchDate == identity.launchDate else { throw DesktopError.targetExpired }
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        let ax = AX.application(identity.pid)
        guard let focused = AX.element(ax, kAXFocusedWindowAttribute),
              AX.string(focused, kAXRoleAttribute) == kAXWindowRole,
              let windows = try? AX.boundedWindowElements(ax), windows.contains(where: { CFEqual($0, focused) }) else { throw DesktopError.targetExpired }
        try Task.checkCancellation()
        guard AX.equal(focused, AX.element(ax, kAXFocusedWindowAttribute)), !app.isTerminated else { throw DesktopError.targetExpired }
        return DesktopWindowTarget(identity: identity, element: focused)
    }
}

extension DesktopService {
    /// 调用入口只读取前台应用的焦点窗口引用。慢应用在一次有界 AX 应答后拒绝，
    /// 窗口角色、成员关系与写入资格仍由异步执行适配器在系统操作前复核。
    public func freezeFrontmostWindow(_ identity: TargetIdentity) throws -> DesktopWindowTarget {
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        guard let birth = identity.launchDate, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == identity.pid, app.launchDate == birth, !app.isTerminated else { throw DesktopError.targetExpired }
        let ax = AXUIElementCreateApplication(identity.pid)
        guard AXUIElementSetMessagingTimeout(ax, 0.05) == .success else { throw DesktopError.targetExpired }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw DesktopError.targetExpired }
        let element = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == identity.pid,
              app.isActive, !app.isTerminated, app.launchDate == birth else { throw DesktopError.targetExpired }
        return DesktopWindowTarget(identity: identity, element: AX.bounded(element))
    }

    public func captureWindowTarget(_ identity: TargetIdentity) async throws -> DesktopWindowTarget {
        let worker = Task.detached(priority: .userInitiated) { try DesktopWindowTarget.capture(identity) }
        let target = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); return target
    }
    public func windowTarget(from snapshot: TargetSnapshot) throws -> DesktopWindowTarget {
        guard let element = snapshot.window, snapshot.launchDate != nil else { throw DesktopError.targetExpired }
        return DesktopWindowTarget(identity: TargetIdentity(pid: snapshot.pid, launchDate: snapshot.launchDate, name: snapshot.applicationName), element: element)
    }
}
