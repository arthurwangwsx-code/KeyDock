import AppKit
import SwiftUI
import WorkbenchFeature
import MacAdapters
import KeyDockUI

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let smoke = (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) || ProcessInfo.processInfo.arguments.contains("--safe-smoke")
            let store = try WorkbenchModel(dataDirectory: smoke ? FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Smoke") : nil, allowContextCapture: !smoke)
            coordinator = WindowCoordinator(store: store, safeSmoke: smoke)
            coordinator?.start()
        } catch {
            let alert = NSAlert(); alert.messageText = "KeyDock"; alert.informativeText = AppL("Local data could not be opened. Existing files were preserved."); alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { coordinator?.presentLauncher(); return true }
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
@MainActor final class WindowCoordinator: NSObject, NSWindowDelegate {
    let store: WorkbenchModel
    let launcherSession: LauncherSession
    let settingsSession: SettingsSession
    let workspaceSession = WorkspaceSession()
    private let hotkeys = HotkeyCenter()
    private let safeSmoke: Bool
    private var launcher: LauncherPanel?
    private var settings: NSWindow?
    private var workspace: NSWindow?
    private var statusItem: NSStatusItem?
    private var generation = UUID()
    private var captureTask: Task<Void, Never>?
    private var originalIdentity: TargetIdentity?
    private var pendingCommandID: String?
    private var capturePending = false
    init(store: WorkbenchModel, safeSmoke: Bool) {
        self.store = store; self.safeSmoke = safeSmoke
        launcherSession = LauncherSession(store: store); settingsSession = SettingsSession(store: store)
        super.init()
        settingsSession.onPaneChanged = { [weak self] in self?.refreshTitles() }
        launcherSession.onExecute = { [weak self] item in
            guard let self else { return }
            store.invalidateLauncherReplies()
            if self.capturePending && item.kind == .ai { self.pendingCommandID = item.id }
            else { store.execute(item) }
        }
        store.onDismiss = { [weak self] in self?.dismissLauncher(restore: $0) }
        store.onOpenSettings = { [weak self] in self?.openSettings($0) }
        store.onOpenWorkspace = { [weak self] in self?.openWorkspace($0) }
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
                catch { self.shortcutError(AppL("Shortcut could not be registered. It may be used by macOS or another application.")) }
            }
        }
    }
    func start() {
        store.startApplicationUpdates(); applyAppearance(); installMenus()
        do { try installShortcuts(configuration: store.configuration) }
        catch { shortcutError(AppL("Shortcut could not be registered. It may be used by macOS or another application.")) }
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
        panel.contentView = KDLauncherSurface.make(root: LauncherView(store: store, session: launcherSession))
        panel.onEscape = { [weak self] in
            if self?.launcherSession.actionsVisible == true { self?.launcherSession.actionsVisible = false }
            else { self?.dismissLauncher(restore: true) }
        }
        return panel
    }
    func presentLauncher(commandID: String? = nil) {
        guard !store.isShuttingDown else { return }
        if launcher == nil { launcher = buildLauncher() }
        guard let launcher else { return }
        if launcher.isKeyWindow {
            if let commandID {
                store.invalidateLauncherReplies()
                if capturePending { pendingCommandID = commandID } else { store.performCommand(id: commandID) }
            }
            return
        }
        generation = UUID(); let current = generation
        captureTask?.cancel(); originalIdentity = safeSmoke ? nil : store.desktop.frontmostTarget()
        let identity = originalIdentity
        capturePending = identity != nil; launcherSession.contextCapturePending = capturePending; pendingCommandID = commandID
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
                if let command = pendingCommandID { pendingCommandID = nil; store.performCommand(id: command) }
            }
        } else if let command = pendingCommandID { pendingCommandID = nil; store.performCommand(id: command) }
    }
    func dismissLauncher(restore: Bool) {
        launcherSession.setVisible(false)
        store.invalidateLauncherReplies()
        generation = UUID(); captureTask?.cancel(); capturePending = false; launcherSession.contextCapturePending = false; pendingCommandID = nil; launcherSession.actionsVisible = false; launcher?.orderOut(nil)
        if restore {
            if let target = store.target { store.desktop.restore(target) }
            else if let originalIdentity { store.desktop.restore(identity: originalIdentity) }
        }
        store.target = nil
    }
    func openSettings(_ pane: SettingsPane? = nil) {
        guard !store.isShuttingDown else { return }
        settingsSession.setVisible(true)
        dismissLauncher(restore: false); if let pane { settingsSession.pane = pane }
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.minSize = NSSize(width: 740, height: 530); window.isReleasedWhenClosed = false; window.delegate = self
            window.toolbarStyle = .unified; window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentViewController = NSHostingController(rootView: SettingsRootView(store: store, session: settingsSession))
            window.setFrameAutosaveName("KeyDock.Settings"); window.center(); settings = window
        }
        refreshTitles(); NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    func openWorkspace(_ route: WorkspaceRoute) {
        guard !store.isShuttingDown else { return }
        workspaceSession.setVisible(true, in: store)
        dismissLauncher(restore: false); workspaceSession.navigate(route, store: store)
        if workspace == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.minSize = NSSize(width: 820, height: 560); window.isReleasedWhenClosed = false; window.delegate = self
            window.toolbarStyle = .unified; window.contentViewController = NSHostingController(rootView: WorkspaceView(store: store, session: workspaceSession))
            window.setFrameAutosaveName("KeyDock.Workspace"); window.center(); workspace = window
        }
        refreshTitles(); NSApp.activate(ignoringOtherApps: true); workspace?.makeKeyAndOrderFront(nil)
    }
    private func refreshTitles() { settings?.title = settingsSession.pane.title + " — KeyDock"; workspace?.title = AppL("Workspace") + " — KeyDock" }
    private func installMenus() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "KeyDock")
        let menu = NSMenu()
        for (title, action, key) in [(AppL("Open KeyDock"), #selector(openLauncherAction), ""), (AppL("Workspace"), #selector(openWorkspaceAction), ""), (AppL("Settings…"), #selector(openSettingsAction), ",")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: AppL("Quit KeyDock"), action: #selector(quitAction), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu; statusItem = item
        let main = NSMenu(); let appItem = NSMenuItem(title: "KeyDock", action: nil, keyEquivalent: "")
        appItem.submenu = menu.copy() as? NSMenu; main.addItem(appItem)
        let fileMenu = NSMenu(title: AppL("File"))
        let close = NSMenuItem(title: AppL("Close Window"), action: #selector(closeWindowAction), keyEquivalent: "w"); close.target = self; fileMenu.addItem(close)
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu; main.addItem(fileItem)
        let editMenu = NSMenu(title: AppL("Edit"))
        for (title, selector, key) in [(AppL("Undo"), Selector(("undo:")), "z"), (AppL("Redo"), Selector(("redo:")), "Z"), (AppL("Cut"), #selector(NSText.cut(_:)), "x"), (AppL("Copy"), #selector(NSText.copy(_:)), "c"), (AppL("Paste"), #selector(NSText.paste(_:)), "v"), (AppL("Select All"), #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let editItem = NSMenuItem(); editItem.submenu = editMenu; main.addItem(editItem)
        NSApp.mainMenu = main
    }
    @objc private func openLauncherAction() { presentLauncher() }
    @objc private func openSettingsAction() { openSettings(settingsSession.pane) }
    @objc private func openWorkspaceAction() { openWorkspace(.tasks(nil)) }
    @objc private func closeWindowAction() { if NSApp.keyWindow === launcher { dismissLauncher(restore: true) } else { NSApp.keyWindow?.performClose(nil) } }
    @objc private func quitAction() { NSApp.terminate(nil) }
    private func shortcutError(_ text: String) { store.shortcutsUnavailable = true; store.settingsNotice = text; store.launcherNotice = text }
    private func installShortcuts(configuration: AppConfiguration) throws {
        guard !store.isShuttingDown else { throw HotkeyRegistrationError(status: -50) }
        let entries = ShortcutPlan.entries(configuration)
        let definitions = entries.map { entry in
            HotkeyDefinition(id: entry.id, binding: entry.binding) { [weak self] in
                guard let self else { return }
                if let command = entry.commandID { self.presentLauncher(commandID: command) }
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
    func deactivate() { if launcher?.isVisible == true { dismissLauncher(restore: false) } }
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === launcher, !launcherSession.actionsVisible else { return }
        dismissLauncher(restore: false)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === workspace { workspaceSession.setVisible(false, in: store) }
        if sender === launcher { dismissLauncher(restore: true); return false }
        if sender === settings { settingsSession.apiKey = ""; settingsSession.setVisible(false) }
        return true
    }
    func beginShutdown() { hotkeys.suspend(); store.shutdown() }
    func prepareForQuit() async { await store.shutdownAndWait() }
    func shutdown() { hotkeys.shutdown(); store.shutdown(); settingsSession.apiKey = "" }
}

private func AppL(_ key: String) -> String { KDLocalizer.string(key, bundle: .main) }
