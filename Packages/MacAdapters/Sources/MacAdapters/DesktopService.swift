import AppKit
@preconcurrency import ApplicationServices
import CommandCore

public enum DesktopError: Error, Sendable {
    case accessibilityRequired, targetExpired, selectionUnavailable, replacementUnsupported
}

/// 应用已经后台打开；只有发起动作的界面仍有效时，宿主才提交前台激活。
@MainActor public struct PreparedApplicationLaunch {
    private let activation: @MainActor () -> Bool
    public init(activation: @escaping @MainActor () -> Bool) { self.activation = activation }
    public func activate() -> Bool { activation() }
}

/// 只含本地进程身份，不发送 AX 消息，可在 Panel 显示前快速捕获。
public struct TargetIdentity: Sendable, Equatable {
    public let pid: pid_t
    public let launchDate: Date?
    public let name: String
    public init(pid: pid_t, launchDate: Date?, name: String) {
        self.pid = pid; self.launchDate = launchDate; self.name = name
    }
}

public final class WindowReference: @unchecked Sendable {
    public let id: String
    public let pid: pid_t
    public let launchDate: Date?
    let element: AXUIElement
    let appName: String
    let title: String
    init(pid: pid_t, launchDate: Date?, element: AXUIElement, appName: String, title: String) {
        self.pid = pid; self.launchDate = launchDate; self.element = element
        self.appName = appName; self.title = title
        id = "window.\(pid).\(launchDate?.timeIntervalSince1970 ?? 0).\(CFHash(element))"
    }
}

/// AX 引用在初始化后只读保留；所有跨进程读写由带限时的 AX helper 执行。
public final class TargetSnapshot: @unchecked Sendable {
    public let pid: pid_t
    public let launchDate: Date?
    public let applicationName: String
    public let selectedText: String?
    let window: AXUIElement?
    let focused: AXUIElement?
    let selectedRange: CFRange?

    init(identity: TargetIdentity) {
        pid = identity.pid; launchDate = identity.launchDate; applicationName = identity.name
        let app = AX.application(pid)
        let initialWindow = AX.element(app, kAXFocusedWindowAttribute)
        let initialFocused = AX.element(app, kAXFocusedUIElementAttribute)
        window = initialWindow

        guard !Task.isCancelled, let initialFocused, !AX.isSecure(initialFocused) else {
            focused = nil; selectedText = nil; selectedRange = nil
            return
        }
        let rangeBefore = AX.range(initialFocused, kAXSelectedTextRangeAttribute)
        let text = AX.string(initialFocused, kAXSelectedTextAttribute)
        let rangeAfter = AX.range(initialFocused, kAXSelectedTextRangeAttribute)
        let finalFocused = AX.element(app, kAXFocusedUIElementAttribute)
        let finalWindow = AX.element(app, kAXFocusedWindowAttribute)
        // 读取过程中原应用可能自行改变焦点；不把跨两个目标拼出的快照作为 AI 输入。
        guard !Task.isCancelled,
              AX.equal(initialFocused, finalFocused), AX.equal(initialWindow, finalWindow),
              AX.equal(rangeBefore, rangeAfter) else {
            focused = nil; selectedText = nil; selectedRange = nil
            return
        }
        focused = initialFocused; selectedText = text; selectedRange = rangeAfter
    }
}

enum AX {
    static let timeout: Float = 0.12

    static func application(_ pid: pid_t) -> AXUIElement {
        bounded(AXUIElementCreateApplication(pid))
    }
    @discardableResult static func bounded(_ element: AXUIElement) -> AXUIElement {
        _ = AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = read(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return bounded(value as! AXUIElement)
    }
    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let value = read(element, attribute), CFGetTypeID(value) == CFArrayGetTypeID(),
              let values = value as? [AnyObject] else { return nil }
        var output: [AXUIElement] = []
        for value in values {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            output.append(bounded(value as! AXUIElement))
        }
        return output
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = read(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }
    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = read(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }
    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }
    static func equal(_ left: AXUIElement?, _ right: AXUIElement?) -> Bool {
        switch (left, right) {
        case let (.some(a), .some(b)): CFEqual(a, b)
        case (.none, .none): true
        default: false
        }
    }
    static func equal(_ left: CFRange?, _ right: CFRange?) -> Bool {
        switch (left, right) {
        case let (.some(a), .some(b)): a.location == b.location && a.length == b.length
        case (.none, .none): true
        default: false
        }
    }
    static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        bounded(element)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}

@MainActor public final class DesktopService {
    public let applicationCatalog: ApplicationCatalog
    private var scanGeneration = UUID()
    private var windowMap: [String: WindowReference] = [:]
    public init(applicationCatalog: ApplicationCatalog = ApplicationCatalog()) { self.applicationCatalog = applicationCatalog }
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func frontmostTarget() -> TargetIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return nil }
        return TargetIdentity(pid: app.processIdentifier, launchDate: app.launchDate, name: app.localizedName ?? "")
    }

    public func captureTarget(_ identity: TargetIdentity) async -> TargetSnapshot? {
        guard matches(identity), !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: .userInitiated) {
            TargetSnapshot(identity: identity)
        }
        let snapshot = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard matches(identity), !Task.isCancelled else { return nil }
        return snapshot
    }

    /// 快照尚未完成时立即关闭 Panel，可以先恢复已捕获的原应用。
    public func restore(identity: TargetIdentity) {
        guard matches(identity), let app = NSRunningApplication(processIdentifier: identity.pid) else { return }
        app.activate()
    }

    public func restore(_ target: TargetSnapshot?) {
        guard let target, let app = NSRunningApplication(processIdentifier: target.pid),
              !app.isTerminated, app.launchDate == target.launchDate else { return }
        if let window = target.window {
            let ax = AX.application(target.pid)
            guard let windows = AX.elements(ax, kAXWindowsAttribute), windows.contains(where: { CFEqual($0, window) }) else { return }
            _ = AXUIElementPerformAction(AX.bounded(window), kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(ax, kAXFocusedWindowAttribute as CFString, window)
        }
        app.activate()
    }

    public func windows() async -> [CommandItem] {
        scanGeneration = UUID(); let currentScan = scanGeneration
        guard accessibilityGranted else { windowMap = [:]; return [] }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let inputs = apps.map { ($0.processIdentifier, $0.launchDate, $0.localizedName ?? "") }
        let worker = Task.detached(priority: .userInitiated) {
            var output: [WindowReference] = []
            for (pid, launch, name) in inputs {
                if Task.isCancelled { break }
                let app = AX.application(pid)
                guard let windows = AX.elements(app, kAXWindowsAttribute) else { continue }
                for window in windows {
                    if Task.isCancelled { break }
                    guard AX.string(window, kAXRoleAttribute) == kAXWindowRole else { continue }
                    let title = AX.string(window, kAXTitleAttribute) ?? ""
                    output.append(WindowReference(pid: pid, launchDate: launch, element: window, appName: name, title: title))
                }
            }
            return output
        }
        let records = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard currentScan == scanGeneration, !Task.isCancelled, accessibilityGranted else { return [] }
        let currentRecords = records.filter { ref in
            guard let app = NSRunningApplication(processIdentifier: ref.pid) else { return false }
            return !app.isTerminated && app.launchDate == ref.launchDate
        }
        windowMap = Dictionary(currentRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return currentRecords.map { CommandItem(id: $0.id, title: $0.title.isEmpty ? $0.appName : $0.title, subtitle: $0.appName, keywords: [$0.appName], kind: .window, payload: $0.id) }
    }

    public func activateWindow(_ id: String) throws {
        guard accessibilityGranted else { throw DesktopError.accessibilityRequired }
        guard let ref = windowMap[id], let app = NSRunningApplication(processIdentifier: ref.pid),
              !app.isTerminated, app.launchDate == ref.launchDate,
              let windows = AX.elements(AX.application(ref.pid), kAXWindowsAttribute),
              windows.contains(where: { CFEqual($0, ref.element) }) else { throw DesktopError.targetExpired }
        if (AX.read(ref.element, kAXMinimizedAttribute) as? Bool) == true {
            guard AXUIElementSetAttributeValue(AX.bounded(ref.element), kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else { throw DesktopError.targetExpired }
        }
        app.activate()
        guard AXUIElementPerformAction(AX.bounded(ref.element), kAXRaiseAction as CFString) == .success else { throw DesktopError.targetExpired }
        _ = AXUIElementSetAttributeValue(AX.application(ref.pid), kAXFocusedWindowAttribute as CFString, ref.element)
    }

    public func launchApplication(_ item: CommandItem) async throws -> PreparedApplicationLaunch {
        let url = try await applicationCatalog.validatedURL(for: item)
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return PreparedApplicationLaunch { application.activate(options: []) }
    }

    public func replaceSelection(_ text: String, target: TargetSnapshot) throws {
        guard accessibilityGranted else { throw DesktopError.accessibilityRequired }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate == target.launchDate, let focused = target.focused,
              let original = target.selectedText, !original.isEmpty else { throw DesktopError.targetExpired }
        guard !AX.isSecure(focused) else { throw DesktopError.replacementUnsupported }
        let ax = AX.application(target.pid)
        guard let current = AX.element(ax, kAXFocusedUIElementAttribute), CFEqual(current, focused),
              AX.string(focused, kAXSelectedTextAttribute) == original else { throw DesktopError.targetExpired }
        if let window = target.window {
            guard let now = AX.element(ax, kAXFocusedWindowAttribute), CFEqual(now, window) else { throw DesktopError.targetExpired }
        }
        // 没有 range 的应用无法证明仍是原选区，只提供复制，避免替换同文的另一处。
        guard let oldRange = target.selectedRange else { throw DesktopError.replacementUnsupported }
        guard let range = AX.range(focused, kAXSelectedTextRangeAttribute), AX.equal(oldRange, range) else { throw DesktopError.targetExpired }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(AX.bounded(focused), kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { throw DesktopError.replacementUnsupported }
        guard AXUIElementSetAttributeValue(AX.bounded(focused), kAXSelectedTextAttribute as CFString, text as CFString) == .success else { throw DesktopError.replacementUnsupported }
        app.activate()
    }

    private func matches(_ identity: TargetIdentity) -> Bool {
        guard identity.pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: identity.pid) else { return false }
        return !app.isTerminated && app.launchDate == identity.launchDate
    }
}
