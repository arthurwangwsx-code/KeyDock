import AppKit
import Carbon
@preconcurrency import ApplicationServices

public enum ClipboardPasteError: Error, Sendable, Equatable {
    case permissionRequired, targetChanged, cancelled, clipboardChanged, eventUnavailable
}

/// 一旦用户切到第三个应用，原目标迟到激活也不能恢复这次输入授权。
@MainActor public final class ClipboardPasteActivationFence {
    private let ownPID: pid_t
    private let targetPID: pid_t
    public private(set) var revoked = false
    public init(ownPID: pid_t, targetPID: pid_t) { self.ownPID = ownPID; self.targetPID = targetPID }
    public func observeActivation(pid: pid_t) {
        if pid != ownPID && pid != targetPID { revoked = true }
    }
}

/// 每个插入事务只有一个不可重放的提交点；接口也用于不接触系统剪贴板的合成验证。
@MainActor public protocol ClipboardPasteDestination {
    var permitted: Bool { get }
    func validate() async -> Bool
    func activate() -> Bool
    var isFrontmost: Bool { get }
    func stageText(_ text: String) throws -> Int
    func dispatchPaste(expectedChange: Int) throws
}

@MainActor public enum ClipboardPasteTransaction {
    public static func perform(_ text: String, destination: any ClipboardPasteDestination,
                               isCurrent: @MainActor () -> Bool) async throws {
        func check() async throws {
            guard !Task.isCancelled, isCurrent() else { throw ClipboardPasteError.cancelled }
            guard destination.permitted else { throw ClipboardPasteError.permissionRequired }
            guard await destination.validate() else { throw ClipboardPasteError.targetChanged }
            // AX校验离开主线程；恢复后消费用户切换／取消产生的围栏，不能沿用await前的授权。
            guard !Task.isCancelled, isCurrent() else { throw ClipboardPasteError.cancelled }
            guard destination.permitted else { throw ClipboardPasteError.permissionRequired }
        }
        try await check()
        guard destination.activate() else { throw ClipboardPasteError.targetChanged }
        let deadline = ContinuousClock.now + .milliseconds(600)
        while !destination.isFrontmost, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15)); try await check()
        }
        try await check()
        guard destination.isFrontmost else { throw ClipboardPasteError.targetChanged }
        let count = try destination.stageText(text)
        // 最终AX校验也不能阻塞主线程；之后紧贴发送核对nonce和changeCount。
        try await check()
        guard destination.isFrontmost else { throw ClipboardPasteError.targetChanged }
        try destination.dispatchPaste(expectedChange: count)
        // 事件一旦发送就不重试，也不宣称接收应用已经消费或落盘。
    }
}

/// 仅捕获输入位置元数据，不读取原应用选区或全文。
public final class ClipboardPasteTarget: @unchecked Sendable {
    public let identity: TargetIdentity
    private let window: AXUIElement
    private let focused: AXUIElement
    private let range: CFRange
    private init(identity: TargetIdentity, window: AXUIElement, focused: AXUIElement, range: CFRange) {
        self.identity = identity; self.window = window; self.focused = focused; self.range = range
    }
    static func capture(_ identity: TargetIdentity) -> ClipboardPasteTarget? {
        guard identity.launchDate != nil, AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        let app = AX.application(identity.pid)
        guard let window = AX.element(app, kAXFocusedWindowAttribute),
              let focused = AX.element(app, kAXFocusedUIElementAttribute), Self.isTextInput(focused),
              let range = AX.range(focused, kAXSelectedTextRangeAttribute) else { return nil }
        guard !Task.isCancelled, AX.equal(window, AX.element(app, kAXFocusedWindowAttribute)),
              AX.equal(focused, AX.element(app, kAXFocusedUIElementAttribute)),
              AX.equal(range, AX.range(focused, kAXSelectedTextRangeAttribute)) else { return nil }
        return ClipboardPasteTarget(identity: identity, window: window, focused: focused, range: range)
    }
    static func from(_ snapshot: TargetSnapshot) -> ClipboardPasteTarget? {
        guard snapshot.launchDate != nil, let window = snapshot.window, let focused = snapshot.focused,
              Self.isTextInput(focused), let range = snapshot.selectedRange else { return nil }
        let value = ClipboardPasteTarget(identity: TargetIdentity(pid: snapshot.pid, launchDate: snapshot.launchDate, name: snapshot.applicationName), window: window, focused: focused, range: range)
        return value.matches() ? value : nil
    }
    private static func isTextInput(_ element: AXUIElement) -> Bool {
        guard !AX.isSecure(element), let role = AX.string(element, kAXRoleAttribute) else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
    fileprivate func matches() -> Bool {
        guard !Task.isCancelled, let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
              app.launchDate == identity.launchDate, AXIsProcessTrusted(), Self.isTextInput(focused) else { return false }
        let ax = AX.application(identity.pid)
        return AX.equal(window, AX.element(ax, kAXFocusedWindowAttribute)) &&
            AX.equal(focused, AX.element(ax, kAXFocusedUIElementAttribute)) &&
            AX.equal(range, AX.range(focused, kAXSelectedTextRangeAttribute)) && !Task.isCancelled
    }
}

extension DesktopService {
    public var clipboardInsertionAvailable: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() && !IsSecureEventInputEnabled() }
    public func pasteTarget(from snapshot: TargetSnapshot) async -> ClipboardPasteTarget? {
        let worker = Task.detached(priority: .userInitiated) { ClipboardPasteTarget.from(snapshot) }
        let target = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        return Task.isCancelled ? nil : target
    }
    public func capturePasteTarget(_ identity: TargetIdentity) async -> ClipboardPasteTarget? {
        let worker = Task.detached(priority: .userInitiated) { ClipboardPasteTarget.capture(identity) }
        let target = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return nil }
        return target
    }
    public func paste(_ text: String, target: ClipboardPasteTarget, isCurrent: @MainActor () -> Bool) async throws {
        try await ClipboardPasteTransaction.perform(text, destination: NativeClipboardPasteDestination(target), isCurrent: isCurrent)
    }
}

@MainActor private final class NativeClipboardPasteDestination: ClipboardPasteDestination {
    let target: ClipboardPasteTarget
    let staging = ClipboardPasteboardStage()
    init(_ target: ClipboardPasteTarget) { self.target = target }
    var permitted: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() && !IsSecureEventInputEnabled() }
    func validate() async -> Bool {
        let target = self.target
        let worker = Task.detached(priority: .userInitiated) { target.matches() }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
    func activate() -> Bool { NSRunningApplication(processIdentifier: target.identity.pid)?.activate() ?? false }
    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.identity.pid }
    func stageText(_ text: String) throws -> Int {
        // 不读取旧剪贴板；用户主动插入的历史文本成为当前纯文本剪贴板。
        try staging.write(text)
    }
    func dispatchPaste(expectedChange: Int) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw ClipboardPasteError.eventUnavailable }
        down.flags = .maskCommand; up.flags = .maskCommand
        guard permitted, isFrontmost else { throw ClipboardPasteError.targetChanged }
        // AX IPC期间也可能有外部写者；所有目标检查后再验证本次nonce及changeCount。
        guard staging.owns(expectedChange) else { throw ClipboardPasteError.clipboardChanged }
        down.postToPid(target.identity.pid); up.postToPid(target.identity.pid)
    }
}

/// 只校验本次生成的私有nonce，不读取已有个人正文；所有类型一次写入。
@MainActor final class ClipboardPasteboardStage {
    static let ownerType = NSPasteboard.PasteboardType("com.arthurwangwsx.KeyDock.paste-owner")
    private let board: NSPasteboard
    private var nonce: String?
    init(board: NSPasteboard = .general) { self.board = board }
    func write(_ text: String, transient: Bool = true) throws -> Int {
        let token = UUID().uuidString
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setString(token, forType: Self.ownerType) else { throw ClipboardPasteError.clipboardChanged }
        if transient, !item.setString("KeyDock", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { throw ClipboardPasteError.clipboardChanged }
        nonce = token; board.clearContents()
        guard board.writeObjects([item]) else { throw ClipboardPasteError.clipboardChanged }
        let count = board.changeCount
        guard owns(count) else { throw ClipboardPasteError.clipboardChanged }
        return count
    }
    func owns(_ count: Int) -> Bool {
        guard let nonce, board.changeCount == count, board.string(forType: Self.ownerType) == nonce else { return false }
        return board.changeCount == count
    }
}
