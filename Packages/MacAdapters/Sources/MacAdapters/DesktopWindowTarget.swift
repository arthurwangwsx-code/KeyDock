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
