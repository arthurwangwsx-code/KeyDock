import AppKit
import SwiftUI
import WorkbenchFeature
import CommandCore
import ExecutionCore
import MacAdapters
import KeyDockUI
import Darwin

@main @MainActor enum KeyDockApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: WindowCoordinator?
    private var terminating = false
    private var dataLease: RuntimeDirectoryLease?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            #if !KEYDOCK_PREVIEW
            // 显式合成域只属于Preview；正式App拒绝此参数，不能误落入真实用户数据域。
            guard !ProcessInfo.processInfo.arguments.contains("--review-fixture-root") else { throw RuntimeDirectoryLeaseError.invalidDirectory }
            #endif
            let smoke = (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) || ProcessInfo.processInfo.arguments.contains("--safe-smoke")
            if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier:id).contains(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated}) { throw RuntimeDirectoryLeaseError.alreadyOwned }
            let directory: URL
            if smoke { directory = try previewDataDirectory() }
            else { directory = try PrivateFiles.applicationDirectory() }
            dataLease = try RuntimeDirectoryLease(directory:directory)
            let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: !smoke)
            coordinator = WindowCoordinator(store: store, safeSmoke: smoke)
            coordinator?.start()
            // 仅隔离Preview可用：使用明确的合成夹具做界面验收，不启用系统采集。
            if smoke && ProcessInfo.processInfo.arguments.contains("--demo-clipboard") {
                coordinator?.loadClipboardDemo()
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "KeyDock"
            alert.informativeText = error as? RuntimeDirectoryLeaseError == .alreadyOwned ? AppL("Another KeyDock instance owns this data directory. Close it before opening this copy.") : AppL("Local data could not be opened. Existing files were preserved.")
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func previewDataDirectory() throws -> URL {
        #if KEYDOCK_PREVIEW
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--review-fixture-root") {
            guard arguments.filter({ $0 == "--review-fixture-root" }).count == 1, index + 1 < arguments.count,
                  Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true,
                  let metadata = Bundle.main.url(forResource: "BuildInfo", withExtension: "json"),
                  let info = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any], info["profile"] as? String == "preview" else { throw RuntimeDirectoryLeaseError.invalidDirectory }
            let path = arguments[index + 1], root = URL(fileURLWithPath: path, isDirectory: true)
            guard path.hasPrefix("/"), root.standardizedFileURL.path == path, root.resolvingSymlinksInPath().path == path,
                  root.lastPathComponent.hasPrefix("KeyDock-Review-"), UUID(uuidString: String(root.lastPathComponent.dropFirst("KeyDock-Review-".count))) != nil else { throw RuntimeDirectoryLeaseError.invalidDirectory }
            var attributes = stat(), markerAttributes = stat()
            let marker = root.appendingPathComponent("synthetic-review.json")
            guard lstat(root.path, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0,
                  lstat(marker.path, &markerAttributes) == 0, markerAttributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), markerAttributes.st_uid == getuid(), markerAttributes.st_mode & 0o077 == 0,
                  markerAttributes.st_nlink == 1, markerAttributes.st_size <= 4096,
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: String], value == ["fixture": "keydock-native-review-v1"] else { throw RuntimeDirectoryLeaseError.invalidDirectory }
            return root.appendingPathComponent("KeyDock-Smoke", isDirectory: true)
        }
        #endif
        return try PrivateFiles.physicalTemporaryDirectory().appendingPathComponent("KeyDock-Smoke")
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { coordinator?.reopen(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }; terminating = true
        coordinator?.beginShutdown()
        Task { await coordinator?.prepareForQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationDidResignActive(_ notification: Notification) { coordinator?.deactivate() }
    func applicationWillTerminate(_ notification: Notification) { coordinator?.shutdown() }
}

@MainActor final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// 只负责窗口生命周期、路由、系统菜单与全局触发；业务服务只有一个 Store。
@MainActor final class WindowCoordinator: NSObject, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let store: WorkbenchModel
    let launcherSession: LauncherSession
    let settingsSession: SettingsSession
    let workspaceSession = WorkspaceSession()
    let clipboardSession: ClipboardPanelSession
    private let hotkeys = HotkeyCenter()
    private let safeSmoke: Bool
    private let visualReview: KDVisualReviewState
    private var launcher: LauncherPanel?
    private var settings: NSWindow?
    private var workspace: NSWindow?
    private var clipboardPanel: LauncherPanel?
    private var clipboardGeneration = UUID()
    private var clipboardCapture: Task<Void, Never>?
    private var clipboardPaste: Task<Void, Never>?
    private var clipboardTarget: ClipboardPasteTarget?
    private var clipboardFence: ClipboardPasteActivationFence?
    private var clipboardActivationObserver: NSObjectProtocol?
    private struct DesktopInvocation {
        let lease: DesktopOperationLease
        let source: TargetIdentity?
        let destinationPath: String?
        let allowsDeactivationAfterSubmission: Bool
        let isWindowCycle: Bool
    }
    private var desktopInvocations: [UUID: DesktopInvocation] = [:]
    private var statusItem: NSStatusItem?
    private var generation = UUID()
    private var captureTask: Task<Void, Never>?
    private var originalIdentity: TargetIdentity?
    private var pendingCommand: ShortcutInvocation?
    private var capturePending = false
    init(store: WorkbenchModel, safeSmoke: Bool) {
        self.store = store; self.safeSmoke = safeSmoke
        #if KEYDOCK_PREVIEW
        let previewBuild = true
        #else
        let previewBuild = false
        #endif
        var buildProfile: String?
        if let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "json"), let data = try? Data(contentsOf: url),
           let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { buildProfile = info["profile"] as? String }
        visualReview = KDVisualReviewState(previewBuild: previewBuild, isolatedPreview: safeSmoke && (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true),
                                          bundleIdentifier: Bundle.main.bundleIdentifier, buildProfile: buildProfile)
        clipboardSession = ClipboardPanelSession(preferences: store.clipboardPreferences)
        launcherSession = LauncherSession(store: store); settingsSession = SettingsSession(store: store)
        super.init()
        settingsSession.onPaneChanged = { [weak self] in self?.refreshTitles() }
        launcherSession.onExecute = { [weak self] item in
            guard let self else { return }
            store.invalidateLauncherReplies()
            if self.capturePending && item.kind == .ai { self.pendingCommand = store.prepareShortcutInvocation(id:item.id) }
            else { store.execute(item) }
        }
        store.onDismiss = { [weak self] in self?.dismissLauncher(restore: $0) }
        store.onOpenSettings = { [weak self] in self?.openSettings($0) }
        store.onOpenShortcutSettings = { [weak self] item in
            self?.settingsSession.focusShortcut(item); self?.openSettings(.shortcuts)
        }
        store.onOpenWorkspace = { [weak self] in self?.openWorkspace($0) }
        store.onOpenClipboard = { [weak self] in self?.presentClipboard() }
        store.onDesktopAction = { [weak self] item, caller in self?.runDesktopAction(item, caller: caller) }
        store.onDesktopActionFinished = { [weak self] id in self?.desktopInvocations[id] = nil }
        clipboardSession.onCopy = { [weak self] text in
            guard let self else { return }; try self.store.copyClipboardSelection(text); self.dismissClipboard(restore: true)
        }
        clipboardSession.onInsert = { [weak self] text, token in self?.insertClipboard(text, token: token) }
        clipboardActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                for invocation in self.desktopInvocations.values {
                    let isSource = invocation.source?.pid == pid && invocation.source?.launchDate == application.launchDate
                    let isDestination = invocation.destinationPath != nil && invocation.destinationPath == application.bundleURL?.path
                    let expectedDeactivation = invocation.allowsDeactivationAfterSubmission && invocation.lease.didSubmit
                    if pid != ProcessInfo.processInfo.processIdentifier && !isSource && !isDestination && !expectedDeactivation { invocation.lease.revoke() }
                }
                guard let fence = self.clipboardFence else { return }
                fence.observeActivation(pid: pid)
                if fence.revoked { self.dismissClipboard(restore: false) }
            }
        }
        store.onCaptureRequested = { [weak self] in
            guard let self else { return }; self.openWorkspace(.tools); store.captureRegion(session:self.workspaceSession)
        }
        store.onAIAction = { [weak self] draft, caller in
            guard let self, store.ownsDraft(draft) else { return }
            self.launcherSession.draft = draft
            if !draft.input.isEmpty, let action = store.configuration.aiActions.first(where: { $0.id == draft.actionID }) { store.runAI(action: action, draft: draft, caller: caller) }
        }
        store.onHistoryRemoved = { [weak self] taskIDs, draftIDs in
            guard let self else { return }
            self.launcherSession.removeHistory(draftIDs: draftIDs)
            self.workspaceSession.removeHistory(taskIDs: taskIDs, draftIDs: draftIDs, in: store)
            self.settingsSession.removeHistory(taskIDs: taskIDs)
        }
        store.onAttemptHistoryChanged = { [weak self] removed in
            guard let self else { return }; self.workspaceSession.attemptHistoryChanged(removed, in: self.store)
        }
        store.onPrepareAttempt = { [weak self] id in
            guard let self else { return }
            self.openWorkspace(.tasks(id)); self.workspaceSession.prepareAttempt(id, in: self.store)
        }
        store.onLanguageChanged = { [weak self] in self?.installMenus(); self?.refreshTitles() }
        store.onAppearanceChanged = { [weak self] in self?.applyAppearance() }
        store.onShortcutConfigurationChanged = { [weak self] configuration in
            guard let self else { throw HotkeyRegistrationError(status: -50) }
            try self.installShortcuts(configuration: configuration)
        }
        store.onShortcutRecordingChanged = { [weak self] recording in
            guard let self, !self.store.isShuttingDown else { return }
            if recording { self.hotkeys.suspend() }
            else {
                do { try self.hotkeys.resume(); try self.installShortcuts(configuration: self.store.configuration) }
                catch { self.store.reportShortcutRegistrationFailure() }
            }
        }
    }
    func start() {
        store.startApplicationUpdates(); applyAppearance(); installMenus()
        do { try installShortcuts(configuration: store.configuration) }
        catch { store.reportShortcutRegistrationFailure() }
        presentLauncher()
    }
    private func applyAppearance() {
        switch store.configuration.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    private func buildLauncher() -> LauncherPanel {
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: KDTokens.launcherWidth, height: KDTokens.launcherHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "KeyDock"; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.delegate = self
        panel.contentView = KDLauncherSurface.make(root: LauncherView(store: store, session: launcherSession), review: visualReview)
        panel.onEscape = { [weak self] in
            if self?.launcherSession.actionsVisible == true { self?.launcherSession.actionsVisible = false }
            else { self?.store.cancelDesktopWorkspaceRuns(); self?.dismissLauncher(restore: true) }
        }
        return panel
    }
    func reopen() {
        guard !store.isShuttingDown else { return }
        if focusTaskMaterialReview() { return }
        // Dock/reopen不能把正在审阅或保存的sheet盖在启动台后面；按当前窗口前后顺序选择。
        for window in NSApp.orderedWindows where (window === settings || window === workspace) && window.isVisible {
            guard window.attachedSheet != nil else { continue }
            var target = window
            while let child = target.attachedSheet, child.isVisible { target = child }
            NSApp.activate(ignoringOtherApps: true); target.makeKeyAndOrderFront(nil)
            return
        }
        presentLauncher()
    }
    func presentLauncher(commandID: String? = nil) {
        guard !store.isShuttingDown else { return }
        if focusTaskMaterialReview() { return }
        let invocation = commandID.flatMap { store.prepareShortcutInvocation(id:$0) }
        if commandID != nil && invocation == nil { return }
        revokeDesktopInvocations()
        dismissClipboard(restore: false)
        if launcher == nil { launcher = buildLauncher() }
        guard let launcher else { return }
        if launcher.isKeyWindow {
            if let invocation {
                store.invalidateLauncherReplies()
                if capturePending { pendingCommand = invocation } else { store.performCommand(invocation) }
            }
            return
        }
        generation = UUID(); let current = generation
        captureTask?.cancel(); originalIdentity = safeSmoke ? nil : store.desktop.frontmostTarget()
        let identity = originalIdentity
        capturePending = identity != nil; launcherSession.contextCapturePending = capturePending; pendingCommand = invocation
        launcherSession.reset(); store.launcherNotice = ""; store.prepareLauncher(target: nil)
        if !launcher.isVisible {
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                var frame = launcher.frame; let visible = screen.visibleFrame
                frame.origin.x = visible.midX - frame.width / 2
                frame.origin.y = visible.maxY - visible.height * 0.22 - frame.height
                frame.origin.y = max(visible.minY + 24, frame.origin.y)
                launcher.setFrame(frame, display: false)
            }
        }
        launcherSession.setVisible(true)
        NSApp.activate(ignoringOtherApps: true); launcher.makeKeyAndOrderFront(nil)
        if let identity {
            captureTask = Task { [weak self] in
                guard let self else { return }
                let snapshot = await store.desktop.captureTarget(identity)
                guard !Task.isCancelled, self.generation == current, launcher.isVisible else { return }
                store.target = snapshot; capturePending = false; launcherSession.contextCapturePending = false
                if let command = pendingCommand { pendingCommand = nil; store.performCommand(command) }
            }
        } else if let command = pendingCommand { pendingCommand = nil; store.performCommand(command) }
    }
    private func runDesktopAction(_ item: CommandItem, caller: ExecutionCaller) {
        guard !store.isShuttingDown else { return }
        if store.isDesktopWorkspace(item) {
            revokeDesktopInvocations()
            guard !safeSmoke, let app = NSWorkspace.shared.frontmostApplication else { store.showError(DesktopError.accessibilityRequired); store.settingsNotice = store.launcherNotice; return }
            let source = TargetIdentity(pid: app.processIdentifier, launchDate: app.launchDate, name: "")
            let invokingWindow = [launcher, settings, workspace].compactMap { $0 }.first { $0.isKeyWindow }
            let display = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
                ? (invokingWindow?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue : nil
            let launcherWasVisible = launcher?.isVisible == true
            var hidden = false
            _ = store.runDesktopWorkspace(item, source: source, invocationDisplayID: display, caller: caller) { [weak self] in
                if launcherWasVisible && !hidden { hidden = true; self?.dismissLauncher(restore: false) }
            }
            return
        }
        let inherited = launcher?.isKeyWindow == true && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let identity = inherited ? originalIdentity : store.desktop.frontmostTarget()
        let isCycle = item.payload == "window-command.focusNext" || item.payload == "window-command.focusPrevious"
        revokeDesktopInvocations(keepingCyclesFor: isCycle ? identity : nil)
        let window = inherited ? store.target.flatMap { try? store.desktop.windowTarget(from: $0) } : nil
        let destination: String?
        let behavior: ApplicationBehavior
        if item.kind == .application { destination = String(item.id.dropFirst(4)); behavior = .launchOrActivate }
        else {
            let definition = store.applicationActions.first(where: { "application-action." + $0.id.uuidString == item.id })
            destination = definition.map { String($0.applicationID.dropFirst(4)) }; behavior = definition?.behavior ?? .launchOrActivate
        }
        let togglesOriginal = behavior == .toggleVisibility && identity.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleURL?.path } == destination
        let allowsDeactivation = behavior == .hide || behavior == .requestQuit || togglesOriginal
        let lease = DesktopOperationLease()
        guard let id = store.runDesktopCommand(item, original: identity, window: window, caller: caller, lease: lease) else { lease.revoke(); return }
        desktopInvocations[id] = DesktopInvocation(lease: lease, source: identity, destinationPath: destination, allowsDeactivationAfterSubmission: allowsDeactivation, isWindowCycle: isCycle)
        dismissClipboard(restore: false)
        dismissLauncher(restore: false)
    }
    private func revokeDesktopInvocations(keepingCyclesFor identity: TargetIdentity? = nil) {
        store.cancelDesktopWorkspaceRuns()
        for invocation in desktopInvocations.values {
            if let identity, invocation.isWindowCycle, invocation.source?.pid == identity.pid, invocation.source?.launchDate == identity.launchDate { continue }
            invocation.lease.revoke()
        }
    }
    func dismissLauncher(restore: Bool) {
        launcherSession.setVisible(false)
        store.invalidateLauncherReplies()
        generation = UUID(); captureTask?.cancel(); capturePending = false; launcherSession.contextCapturePending = false; pendingCommand = nil; launcherSession.actionsVisible = false; launcher?.orderOut(nil)
        if restore {
            if let target = store.target { store.desktop.restore(target) }
            else if let originalIdentity { store.desktop.restore(identity: originalIdentity) }
        }
        store.target = nil
    }
    func openSettings(_ pane: SettingsPane? = nil) {
        guard !store.isShuttingDown else { return }
        revokeDesktopInvocations()
        dismissClipboard(restore: false)
        settingsSession.setVisible(true)
        dismissLauncher(restore: false); if let pane { settingsSession.pane = pane }
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 740, height: 530); window.isReleasedWhenClosed = false; window.delegate = self
            window.toolbarStyle = .unified; window.standardWindowButton(.zoomButton)?.isHidden = true
            installContent(SettingsRootView(store: store, session: settingsSession), in: window)
            window.setFrameAutosaveName("KeyDock.Settings"); window.center(); settings = window
            installToolbar("KeyDock.Settings.Toolbar", in: window)
        }
        refreshTitles(); NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    func openWorkspace(_ route: WorkspaceRoute? = nil) {
        guard !store.isShuttingDown else { return }
        revokeDesktopInvocations()
        dismissClipboard(restore: false)
        workspaceSession.present(route, in: store)
        dismissLauncher(restore: false)
        if workspace == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 820, height: 560); window.isReleasedWhenClosed = false; window.delegate = self
            window.toolbarStyle = .unified; installContent(WorkspaceView(store: store, session: workspaceSession), in: window)
            window.setFrameAutosaveName("KeyDock.Workspace"); window.center(); workspace = window
            installToolbar("KeyDock.Workspace.Toolbar", in: window)
        }
        refreshTitles(); NSApp.activate(ignoringOtherApps: true); workspace?.makeKeyAndOrderFront(nil)
    }
    func presentClipboard() {
        guard !store.isShuttingDown else { return }
        if focusTaskMaterialReview() { return }
        revokeDesktopInvocations()
        if clipboardPanel?.isKeyWindow == true { dismissClipboard(restore: true); return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let fromLauncher = launcher?.isKeyWindow == true && NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
        let inherited = fromLauncher ? store.target : nil
        // 复制/Esc只需应用身份；不能因为没有AX输入权限就丢失返回路径。
        let identity = safeSmoke ? nil : (fromLauncher ? originalIdentity : store.desktop.frontmostTarget())
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        dismissClipboard(restore: false)
        let request = clipboardGeneration
        clipboardCapture = Task { [weak self] in
            guard let self else { return }
            let captured: ClipboardPasteTarget?
            if let inherited { captured = await store.desktop.pasteTarget(from: inherited) }
            else if !fromLauncher, let identity { captured = await store.desktop.capturePasteTarget(identity) }
            else { captured = nil }
            // 抢焦点前完成元数据捕获；用户已经转去另一应用时不迟到抢回焦点。
            guard !Task.isCancelled, clipboardGeneration == request, !store.isShuttingDown,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { return }
            dismissLauncher(restore: false)
            clipboardTarget = captured
            if clipboardPanel == nil {
                let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = AppL("Clipboard history"); panel.backgroundColor = .clear; panel.isOpaque = false
                panel.hasShadow = true; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
                panel.isFloatingPanel = true; panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.delegate = self
                panel.isMovableByWindowBackground = true
                panel.contentView = KDLauncherSurface.make(root: ClipboardPanelView(store: store, session: clipboardSession, dismiss: { [weak self] in self?.dismissClipboard(restore: true) }), review: visualReview)
                panel.onEscape = { [weak self] in self?.dismissClipboard(restore: true) }
                clipboardPanel = panel
            }
            clipboardSession.present(access: store.clipboardStore, returnTarget: identity ?? captured?.identity, onMutation: { [weak self] in self?.store.refreshClipboard() })
            clipboardSession.canInsert = captured != nil && !safeSmoke && store.desktop.clipboardInsertionAvailable
            clipboardSession.targetName = captured?.identity.name ?? ""
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main, let panel = clipboardPanel {
                var frame = panel.frame; frame.origin.x = screen.visibleFrame.midX - frame.width / 2
                frame.origin.y = max(screen.visibleFrame.minY + 24, screen.visibleFrame.midY - frame.height / 2)
                panel.setFrame(frame, display: false)
            }
            NSApp.activate(ignoringOtherApps: true); clipboardPanel?.makeKeyAndOrderFront(nil)
        }
    }
    private func dismissClipboard(restore: Bool) {
        let identity = clipboardSession.returnTarget
        clipboardGeneration = UUID(); clipboardCapture?.cancel(); clipboardCapture = nil
        clipboardPaste?.cancel(); clipboardPaste = nil
        clipboardPanel?.orderOut(nil); clipboardSession.dismiss(); clipboardTarget = nil; clipboardFence = nil
        if restore, let identity { store.desktop.restore(identity: identity) }
    }
    private func insertClipboard(_ text: String, token: UUID) {
        guard !store.isShuttingDown, clipboardPaste == nil, let target = clipboardTarget, !safeSmoke, clipboardSession.acceptsCommit(token) else { return }
        let request = clipboardGeneration
        let fence = ClipboardPasteActivationFence(ownPID: ProcessInfo.processInfo.processIdentifier, targetPID: target.identity.pid)
        clipboardFence = fence
        // 提交期间只隐藏，不触发用户dismiss；事务有独立nonce，新入口会撤销它。
        clipboardPanel?.orderOut(nil)
        clipboardPaste = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.insertClipboardText(text, target: target, isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.clipboardGeneration == request && !self.store.isShuttingDown && self.clipboardSession.acceptsCommit(token) && !fence.revoked
                })
                if clipboardGeneration == request { dismissClipboard(restore: false) }
            } catch {
                guard clipboardGeneration == request, !Task.isCancelled, !store.isShuttingDown else { return }
                clipboardPaste = nil; clipboardTarget = nil; clipboardFence = nil; clipboardSession.canInsert = false
                clipboardSession.reportInsertionFailure()
                // 失败提示不抢回其他应用的键盘焦点，也不会自动重试。
                clipboardPanel?.orderFrontRegardless()
            }
        }
    }
    private func installContent<Content: View>(_ content: Content, in window: NSWindow) {
        let hosting = NSHostingController(rootView: KDVisualReviewHost(review: visualReview) { content })
        // AppKit独占窗口尺寸与工具栏，SwiftUI负责正文。
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        window.contentViewController = hosting
    }
    private func installToolbar(_ name: String, in window: NSWindow) {
        let toolbar = NSToolbar(identifier: name)
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unified
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("KeyDock.Controls")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier.rawValue == "KeyDock.Controls" else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        if toolbar.identifier == "KeyDock.Workspace.Toolbar" {
            item.view = NSHostingView(rootView: KDVisualReviewHost(review: visualReview) { WorkspaceToolbarView(store: store, session: workspaceSession) })
        } else { configureSettingsToolbarItem(item) }
        return item
    }
    private func configureSettingsToolbarItem(_ item: NSToolbarItem) {
        let command = settingsSession.pane == .commands
        let title = command ? AppL("New command") : AppL("New action")
        item.label = title; item.toolTip = title
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: title)
        item.target = self; item.action = command ? #selector(newCommandAction) : #selector(newAIAction)
    }
    private func refreshTitles() {
        clipboardPanel?.title = AppL("Clipboard history")
        settings?.title = settingsSession.pane.title + " — KeyDock"
        if let item = settings?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "KeyDock.Controls" }) {
            configureSettingsToolbarItem(item)
        }
        settings?.toolbar?.isVisible = settingsSession.pane == .commands || settingsSession.pane == .aiActions
        workspace?.title = AppL("Workspace") + " — KeyDock"
    }
    private var workspaceSheetOwnsKeyboard: Bool {
        guard let workspace, let key = NSApp.keyWindow else { return false }
        let belongs = key === workspace || key.sheetParent === workspace || workspace.attachedSheet.map { key === $0 || key.sheetParent === $0 } == true
        return belongs && (workspaceSession.hasPendingOrDismissingModal || workspace.attachedSheet != nil)
    }
    private var keyboardDraft: AIDraftDocument? {
        guard !workspaceSheetOwnsKeyboard, let keyWindow = NSApp.keyWindow else { return nil }
        if keyWindow === workspace, workspaceSession.page == .ai { return workspaceSession.draft }
        if keyWindow === launcher { return launcherSession.draft }
        return nil
    }
    private var keyboardCancellationID: UUID? {
        guard !workspaceSheetOwnsKeyboard, let keyWindow = NSApp.keyWindow else { return nil }
        let id: UUID?
        if keyWindow === workspace, workspaceSession.page == .tasks { id = workspaceSession.selectedTaskID }
        else { id = keyboardDraft?.latestRunID }
        return store.tasks.first { $0.id == id && $0.canCancel }?.id
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(visualPresetAction(_:)) {
            menuItem.state = menuItem.tag == visualReview.preset.rawValue ? .on : .off
            return visualReview.allowsChanges && safeSmoke && !store.isShuttingDown
        }
        if menuItem.action == #selector(runCurrentAction) {
            // 模态输入拥有键盘；不能让主窗口的快捷键运行被遮住的编辑稿。
            if workspaceSheetOwnsKeyboard || !store.canCommitCurrentInput { return false }
            if NSApp.keyWindow === clipboardPanel {
                let alternate = clipboardSession.preferences.primaryAction.alternate
                menuItem.title = alternate == .copy ? AppL("Copy clipboard selection") : AppL("Insert clipboard selection")
                return !store.isShuttingDown && clipboardSession.canCommit && (alternate == .copy || clipboardSession.canInsert)
            }
            // Return只有一个菜单owner；同一keyEquivalent的禁用项仍可能挡住后续项。
            if NSApp.keyWindow === workspace, workspaceSession.page == .agent {
                menuItem.title = AppL("Run agent")
                return !store.isShuttingDown && !workspaceSession.agentInput.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            }
            if NSApp.keyWindow === workspace, workspaceSession.page == .workflows {
                menuItem.title = AppL("Run workflow")
                return !store.isShuttingDown && !workspaceSession.workflowDraft.name.isEmpty
            }
            menuItem.title = AppL("Run AI action")
            return store.canRunAIFromInput(keyboardDraft)
        }
        if menuItem.action == #selector(stopCurrentTaskAction) { return !store.isShuttingDown && keyboardCancellationID != nil }
        return !store.isShuttingDown
    }
    private func installMenus() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "KeyDock")
        let menu = NSMenu()
        for (title, action, key) in [(AppL("Open KeyDock"), #selector(openLauncherAction), ""), (AppL("Clipboard history"), #selector(openClipboardAction), ""), (AppL("Workspace"), #selector(openWorkspaceAction), ""), (AppL("Settings…"), #selector(openSettingsAction), ",")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: AppL("Quit KeyDock"), action: #selector(quitAction), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu; statusItem = item
        let main = NSMenu(); let appItem = NSMenuItem(title: "KeyDock", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "KeyDock")
        let about = NSMenuItem(title: AppL("About KeyDock"), action: #selector(openAboutAction), keyEquivalent: ""); about.target = self; appMenu.addItem(about)
        appMenu.addItem(.separator())
        let preferences = NSMenuItem(title: AppL("Settings…"), action: #selector(openSettingsAction), keyEquivalent: ","); preferences.target = self; appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        let appQuit = NSMenuItem(title: AppL("Quit KeyDock"), action: #selector(quitAction), keyEquivalent: "q"); appQuit.target = self; appMenu.addItem(appQuit)
        appItem.submenu = appMenu; main.addItem(appItem)
        let fileMenu = NSMenu(title: AppL("File"))
        let newAI = NSMenuItem(title: AppL("New AI task"), action: #selector(newAITaskAction), keyEquivalent: "n"); newAI.target = self; fileMenu.addItem(newAI)
        let run = NSMenuItem(title:AppL("Run AI action"),action:#selector(runCurrentAction),keyEquivalent:"\r")
        run.target = self; run.keyEquivalentModifierMask = .command; fileMenu.addItem(run)
        let stop = NSMenuItem(title: AppL("Stop current task"), action: #selector(stopCurrentTaskAction), keyEquivalent: "."); stop.target = self; fileMenu.addItem(stop)
        fileMenu.addItem(.separator())
        let close = NSMenuItem(title: AppL("Close Window"), action: #selector(closeWindowAction), keyEquivalent: "w"); close.target = self; fileMenu.addItem(close)
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu; main.addItem(fileItem)
        let editMenu = NSMenu(title: AppL("Edit"))
        for (title, selector, key) in [(AppL("Undo"), Selector(("undo:")), "z"), (AppL("Redo"), Selector(("redo:")), "Z"), (AppL("Cut"), #selector(NSText.cut(_:)), "x"), (AppL("Copy"), #selector(NSText.copy(_:)), "c"), (AppL("Paste"), #selector(NSText.paste(_:)), "v"), (AppL("Select All"), #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let editItem = NSMenuItem(); editItem.submenu = editMenu; main.addItem(editItem)
        let viewMenu = NSMenu(title: AppL("View"))
        for (title, selector) in [(AppL("Open KeyDock"), #selector(openLauncherAction)), (AppL("Clipboard history"), #selector(openClipboardAction)), (AppL("Workspace"), #selector(openWorkspaceAction))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; viewMenu.addItem(entry)
        }
        let viewItem = NSMenuItem(); viewItem.submenu = viewMenu; main.addItem(viewItem)
        if safeSmoke {
            let previewMenu = NSMenu(title: AppL("Preview"))
            let demo = NSMenuItem(title: AppL("Sample clipboard history"), action: #selector(openClipboardDemoAction), keyEquivalent: "")
            demo.target = self; previewMenu.addItem(demo)
            if visualReview.allowsChanges {
                let attempts = NSMenuItem(title: AppL("Sample task attempts"), action: #selector(openAttemptDemoAction), keyEquivalent: "")
                attempts.target = self; previewMenu.addItem(attempts)
                let workspaceSample = NSMenuItem(title: AppL("Sample workspace results"), action: #selector(openWorkspaceResultsDemoAction), keyEquivalent: "")
                workspaceSample.target = self; previewMenu.addItem(workspaceSample)
                let samples = NSMenuItem(title: AppL("Visual samples (KeyDock controls)"), action: nil, keyEquivalent: "")
                let presets = NSMenu(title: samples.title)
                for (preset, title) in [(KDVisualReviewPreset.system, AppL("Follow system visuals")), (.contrast, AppL("Higher contrast sample")), (.opaque, AppL("Opaque surface sample")), (.motion, AppL("Reduced motion sample")), (.all, AppL("All visual samples"))] {
                    let entry = NSMenuItem(title: title, action: #selector(visualPresetAction(_:)), keyEquivalent: "")
                    entry.target = self; entry.tag = preset.rawValue; presets.addItem(entry)
                }
                samples.submenu = presets; previewMenu.addItem(samples)
            }
            let previewItem = NSMenuItem(); previewItem.submenu = previewMenu; main.addItem(previewItem)
        }
        NSApp.mainMenu = main
    }
    @objc private func openWorkspaceResultsDemoAction() {
        #if KEYDOCK_PREVIEW
        guard safeSmoke, visualReview.allowsChanges, !store.isShuttingDown,
              let id = UUID(uuidString: "ED000000-0000-4000-8000-000000000001") else { return }
        var result = DesktopWorkspaceRunResult(entryIDs: (0..<3).map { _ in UUID() })
        result.entries[0].launch = .notRequired; result.entries[0].focus = .confirmed; result.entries[0].layout = .confirmed
        result.entries[1].launch = .confirmed; result.entries[1].focus = .confirmed; result.entries[1].layout = .unknown
        var task = RunningTaskItem(id: id, title: AppL("Sample workspace results"), state: .interrupted, finishedAt: Date())
        task.desktopWorkspaceResult = result
        task.desktopWorkspaceLabels = Dictionary(uniqueKeysWithValues: zip(result.entries.map(\.entryID), [AppL("Browser sample"), AppL("Editor sample"), AppL("Notes sample")]))
        store.tasks.removeAll { $0.id == id }; store.tasks.insert(task, at: 0)
        openWorkspace(.tasks(id))
        #endif
    }
    @objc private func openAttemptDemoAction() {
        #if KEYDOCK_PREVIEW
        guard safeSmoke, visualReview.allowsChanges, !store.isShuttingDown, !workspaceSession.hasPendingOrDismissingModal else { return }
        // 隔离Preview里也走真正的保存／执行入口；仅固定printf和纯文本变换，无外部服务或桌面上下文。
        let command = SavedCommand(name: "Synthetic printf attempt", executable: "/usr/bin/printf", arguments: ["Synthetic previous CLI result"], workingDirectory: FileManager.default.temporaryDirectory.path)
        if store.saveCommand(command) { store.runCommand(command) }
        let workflow = store.configuration.workflows.first { $0.name == "Synthetic uppercase attempt" }
            ?? .init(name: "Synthetic uppercase attempt", steps: [.init(operation: .transform(.uppercase))])
        guard store.saveWorkflow(workflow), let current = store.configuration.workflows.first(where: { $0.id == workflow.id }),
              let id = store.runWorkflow(current, input: "Synthetic previous workflow input") else { return }
        openWorkspace(.tasks(id))
        #endif
    }
    @objc private func openClipboardDemoAction() { loadClipboardDemo() }
    @objc private func visualPresetAction(_ sender: NSMenuItem) {
        guard safeSmoke, visualReview.allowsChanges, !store.isShuttingDown, let preset = KDVisualReviewPreset(rawValue: sender.tag) else { return }
        visualReview.select(preset)
    }
    func loadClipboardDemo() {
        guard safeSmoke, !store.isShuttingDown else { return }
        Task { [weak self] in
            guard let self else { return }
            for text in ["KeyDock clipboard demo\nSearch with arrow keys. Copy with Command-Return.\nSynthetic text only.", "会议摘要示例\n核对快捷键、窗口控制与中英文界面。\n这是一段合成验收文本。", "https://example.com/search?q=KeyDock"] {
                _ = try? await store.clipboardStore.insert(text: text, source: "KeyDock Synthetic Demo")
            }
            guard !store.isShuttingDown else { return }
            presentClipboard()
        }
    }
    @objc private func openLauncherAction() { presentLauncher() }
    @objc private func openClipboardAction() { presentClipboard() }
    @objc private func openSettingsAction() { openSettings(settingsSession.pane) }
    @objc private func openWorkspaceAction() { openWorkspace() }
    @objc private func newAITaskAction() { workspaceSession.createDraft(in: store); openWorkspace() }
    @objc private func newCommandAction() { settingsSession.beginNewCommand() }
    @objc private func newAIAction() { settingsSession.beginNewAction() }
    @objc private func runCurrentAction() {
        guard store.canCommitCurrentInput, !workspaceSheetOwnsKeyboard else { return }
        if NSApp.keyWindow === clipboardPanel { clipboardSession.commitAlternate() }
        else if NSApp.keyWindow === workspace, workspaceSession.page == .agent { runAgentAction() }
        else if NSApp.keyWindow === workspace, workspaceSession.page == .workflows { runWorkflowAction() }
        else { runAIAction() }
    }
    @objc private func runAIAction() { store.runAIFromInput(keyboardDraft) }
    @objc private func runAgentAction() {
        guard store.canCommitCurrentInput, NSApp.keyWindow === workspace, workspaceSession.page == .agent else { return }
        store.runAgent(workspaceSession.agentProfile, input: workspaceSession.agentInput)
    }
    @objc private func runWorkflowAction() {
        guard store.canCommitCurrentInput, NSApp.keyWindow === workspace, workspaceSession.page == .workflows else { return }
        store.runWorkflow(workspaceSession.workflowDraft,input:workspaceSession.workflowInput)
    }
    @objc private func stopCurrentTaskAction() { if let id = keyboardCancellationID { store.cancelTask(id) } }
    @objc private func openAboutAction() { openSettings(.about) }
    @objc private func closeWindowAction() {
        if NSApp.keyWindow === clipboardPanel { dismissClipboard(restore: true) }
        else if NSApp.keyWindow === launcher { dismissLauncher(restore: true) }
        else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc private func quitAction() { NSApp.terminate(nil) }
    private func focusTaskMaterialReview() -> Bool {
        guard workspaceSession.ownsTaskMaterialReview else { return false }
        if var target = workspace {
            while let child = target.attachedSheet, child.isVisible { target = child }
            NSApp.activate(ignoringOtherApps: true); target.makeKeyAndOrderFront(nil)
        }
        return true
    }
    private func installShortcuts(configuration: AppConfiguration) throws {
        guard !store.isShuttingDown else { throw HotkeyRegistrationError(status: -50) }
        let entries = ShortcutPlan.entries(configuration)
        let definitions = entries.map { entry in
            HotkeyDefinition(id: entry.id, binding: entry.binding) { [weak self] in
                guard let self else { return }
                if self.focusTaskMaterialReview() { return }
                if entry.commandID == "utility.clipboard" { self.presentClipboard() }
                else if let command = entry.commandID, command.hasPrefix("desktop-workspace.") { self.store.performDesktopWorkspaceShortcut(id: command) }
                else if let command = entry.commandID, self.store.isDesktopCommand(command) { self.store.desktopShortcut(command) }
                else if entry.commandID == "utility.desktop-workspaces" { self.store.performCommand(id: "utility.desktop-workspaces") }
                else if let command = entry.commandID, command.hasPrefix("workflow.") {
                    self.revokeDesktopInvocations(); self.dismissClipboard(restore: false); self.dismissLauncher(restore: false)
                    self.store.performWorkflowShortcut(id: command)
                }
                else if let command = entry.commandID, self.store.isSavedToolShortcut(command) {
                    guard let invocation = self.store.prepareSavedToolShortcut(id: command) else { return }
                    self.revokeDesktopInvocations(); self.dismissClipboard(restore: false); self.dismissLauncher(restore: false)
                    // 三类工具不需要原目标；复制完成后的通用dismiss也不能恢复旧Launcher目标。
                    self.originalIdentity = nil
                    self.store.performCommand(invocation)
                }
                else if let command = entry.commandID { self.presentLauncher(commandID: command) }
                else if self.launcher?.isKeyWindow == true { self.dismissLauncher(restore: true) }
                else { self.presentLauncher() }
            }
        }
        do { try hotkeys.replace(definitions); store.shortcutsUnavailable = false }
        catch {
            // 恢复已提交配置失败时，不能把刚刚注册的新配置继续留在 OS 中。
            if entries == ShortcutPlan.entries(store.configuration) { hotkeys.invalidate() }
            store.shortcutsUnavailable = hotkeys.isUnavailable
            throw error
        }
    }
    func deactivate() {
        if launcher?.isVisible == true { dismissLauncher(restore: false) }
        if clipboardPanel?.isVisible == true && clipboardPaste == nil { dismissClipboard(restore: false) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === clipboardPanel {
            if clipboardPanel?.isVisible == true && clipboardPaste == nil { dismissClipboard(restore: false) }
            return
        }
        guard let window = notification.object as? NSWindow, window === launcher, !launcherSession.actionsVisible else { return }
        dismissLauncher(restore: false)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === workspace { workspaceSession.setVisible(false, in: store) }
        if sender === launcher { dismissLauncher(restore: true); return false }
        if sender === clipboardPanel { dismissClipboard(restore: true); return false }
        if sender === settings { settingsSession.apiKey = ""; settingsSession.setVisible(false) }
        return true
    }
    func beginShutdown() { settingsSession.invalidateSettingsSummaryExport(); settingsSession.invalidateConfigurationExport(); settingsSession.invalidateSourceRemoval(); workspaceSession.invalidateSourceRemoval(); workspaceSession.invalidateAttemptPreparation(); dismissClipboard(restore: false); hotkeys.suspend(); store.shutdown() }
    func prepareForQuit() async { await store.shutdownAndWait() }
    func shutdown() {
        if let observer = clipboardActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; clipboardActivationObserver = nil
        hotkeys.shutdown(); store.shutdown(); settingsSession.apiKey = ""; settingsSession.invalidateSettingsSummaryExport(); settingsSession.invalidateConfigurationExport(); settingsSession.invalidateSourceRemoval(); workspaceSession.invalidateSourceRemoval()
    }
}

private func AppL(_ key: String) -> String { KDLocalizer.string(key, bundle: .main) }
