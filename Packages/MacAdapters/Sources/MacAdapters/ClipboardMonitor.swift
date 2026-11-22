import AppKit

@MainActor public final class ClipboardMonitor {
    public var enabled = false { didSet { if enabled != oldValue { lastChange = NSPasteboard.general.changeCount } } }
    public var excludedApplications: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess"]
    public var onChange: (@MainActor () -> Void)?
    public var onFailure: (@MainActor () -> Void)?
    private let store: ClipboardStore
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastChange: Int
    private var suspended = false
    private var capturing = false
    private var lastPrune = Date.distantPast
    public init(store: ClipboardStore) {
        self.store = store; lastChange = NSPasteboard.general.changeCount
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspended = true } })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspended = false; self?.lastChange = NSPasteboard.general.changeCount } })
        }
    }
    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in Task { @MainActor in await self?.tick() } }
    }
    public func stop() {
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers = []
    }
    private func tick() async {
        guard !capturing else { return }
        if Date().timeIntervalSince(lastPrune) > 60 {
            lastPrune = Date()
            do { try await store.prune(); onChange?() } catch { onFailure?() }
        }
        guard enabled, !suspended else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        let capturedChange = pasteboard.changeCount
        lastChange = capturedChange
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let types = pasteboard.types?.map(\.rawValue) ?? []
        // 先检查类型和排除范围，再读取正文；前台应用仅作为来源提示。
        guard ClipboardPolicy.allows(types: types, source: source, excluded: excludedApplications),
              let text = pasteboard.string(forType: .string), !text.isEmpty,
              pasteboard.changeCount == capturedChange,
              ClipboardPolicy.allows(types: pasteboard.types?.map(\.rawValue) ?? [], source: source, excluded: excludedApplications) else { return }
        capturing = true; defer { capturing = false }
        do { try await store.insert(text: text, source: source ?? ""); onChange?() }
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
