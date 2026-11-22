import AppKit

/// 元数据与正文分离；敏感判断通过后才允许调用惰性的正文读取。
@MainActor public protocol ClipboardCaptureSource: AnyObject {
    var changeCount: Int { get }
    var availableTypes: [String] { get }
    var sourceApplication: String? { get }
    func readText() -> String?
}

@MainActor private final class GeneralClipboardSource: ClipboardCaptureSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
    var availableTypes: [String] { NSPasteboard.general.types?.map(\.rawValue) ?? [] }
    var sourceApplication: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    func readText() -> String? { NSPasteboard.general.string(forType: .string) }
}

@MainActor public final class ClipboardMonitor {
    public var enabled = false { didSet { if enabled != oldValue { lastChange = source.changeCount } } }
    public var excludedApplications: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess"]
    public var onChange: (@MainActor () -> Void)?
    public var onFailure: (@MainActor () -> Void)?
    public var onCaptureIssue: (@MainActor (ClipboardRejection?) -> Void)?
    private let store: ClipboardStore
    private let source: any ClipboardCaptureSource
    private var timer: Timer?
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []
    private var lastChange: Int
    private var suspended = false
    private var capturing = false
    private var lastPrune = Date.distantPast
    public init(store: ClipboardStore, source: (any ClipboardCaptureSource)? = nil) {
        self.store = store; self.source = source ?? GeneralClipboardSource()
        lastChange = self.source.changeCount
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspendCapture() } })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resumeCapture() } })
        }
    }
    public func start() {
        guard timer == nil else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in Task { @MainActor in await self?.poll() } }
    }
    public func stop() {
        isRunning = false; timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
    }
    func suspendCapture() { suspended = true }
    func resumeCapture() { suspended = false; lastChange = source.changeCount }
    func poll() async {
        guard isRunning, !capturing else { return }
        capturing = true; defer { capturing = false }
        if Date().timeIntervalSince(lastPrune) > 60 {
            lastPrune = Date()
            do { try await store.prune(); onChange?() } catch { onFailure?() }
        }
        guard isRunning, enabled, !suspended else { return }
        guard source.changeCount != lastChange else { return }
        let capturedChange = source.changeCount
        lastChange = capturedChange
        let application = source.sourceApplication
        let types = source.availableTypes
        // 先检查类型和排除范围，再读取正文；前台应用仅作为来源提示。
        guard ClipboardPolicy.allows(types: types, source: application, excluded: excludedApplications),
              source.changeCount == capturedChange,
              let text = source.readText(), !text.isEmpty,
              source.changeCount == capturedChange,
              ClipboardPolicy.allows(types: source.availableTypes, source: application, excluded: excludedApplications) else { return }
        do {
            let result = try await store.insert(text: text, source: application ?? "")
            guard isRunning else { return }
            switch result {
            case .stored, .refreshed: onCaptureIssue?(nil); onChange?()
            case .rejected(let reason): onCaptureIssue?(reason)
            case .ignoredEmpty: break
            }
        }
        catch { onFailure?() }
    }
    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    public static func explicitTextInput() -> String? {
        let pb = NSPasteboard.general
        guard ClipboardPolicy.allows(types: pb.types?.map(\.rawValue) ?? [], source: nil, excluded: []) else { return nil }
        let count = pb.changeCount
        let text = pb.string(forType: .string)
        guard pb.changeCount == count, ClipboardPolicy.allows(types: pb.types?.map(\.rawValue) ?? [], source: nil, excluded: []) else { return nil }
        return text
    }
}
