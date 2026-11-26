import AppKit
import SwiftUI
import WorkbenchFeature
import MacAdapters
import KeyDockUI
import ExecutionCore
import OSLog

@MainActor protocol KeyDockWindowCoordinating: AnyObject {
    func start()
    func reopen()
    func deactivate()
    func beginShutdown()
    func prepareForQuit() async
    func shutdown()
}

/// Review只组合生产剪贴板组件；不构造Launcher、Workspace或通用设置会话。
@MainActor final class DesktopReviewCoordinator: NSObject, KeyDockWindowCoordinating, NSWindowDelegate, NSMenuItemValidation {
    private let store: WorkbenchModel
    private let scope: DesktopReviewScope
    private let session: ClipboardPanelSession
    private let hotkeys = HotkeyCenter()
    private let editor = KDRestrictedFieldEditor(frame: .zero)
    private let visual = KDVisualReviewState(previewBuild: false, isolatedPreview: false, bundleIdentifier: nil, buildProfile: nil)
    private var settings: NSWindow?
    private var panel: LauncherPanel?
    private var statusItem: NSStatusItem?
    private var generation = UUID()
    private var capture: Task<Void, Never>?
    private var paste: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var target: ClipboardPasteTarget?
    private var fence: ClipboardPasteActivationFence?
    private var preparingTarget = false
    private var stopping = false
    private let taskLifetime = OwnedTaskLifetime()
    private var activationObserver: NSObjectProtocol?
    init(store: WorkbenchModel, scope: DesktopReviewScope) {
        self.store = store; self.scope = scope
        session = ClipboardPanelSession(preferences: store.clipboardPreferences)
        super.init()
        store.onOpenSettings = { [weak self] _ in self?.openSettings() }
        store.onLanguageChanged = { [weak self] in self?.installMenus(); self?.refreshTitles() }
        store.onAppearanceChanged = { [weak self] in self?.applyAppearance() }
        store.onShortcutConfigurationChanged = { [weak self] configuration in
            guard let self else { throw DesktopReviewError.unavailable }
            try self.installShortcuts(configuration)
        }
        store.onShortcutRecordingChanged = { [weak self] recording in
            guard let self else { return }
            if recording { self.hotkeys.suspend() }
            else if self.store.desktopReviewAvailable {
                do { try self.hotkeys.resume() } catch { self.store.reportShortcutRegistrationFailure() }
            } else { self.hotkeys.invalidate() }
        }
        session.onCopy = { [weak self] text in
            guard let self, self.store.desktopReviewAvailable else { throw DesktopReviewError.unavailable }
            try self.store.copyClipboardSelection(text); self.dismiss(restore: true)
        }
        session.onInsert = { [weak self] text, token in self?.insert(text, token: token) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.preparingTarget && pid != ProcessInfo.processInfo.processIdentifier && pid != self.scope.targetIdentity.pid { self.dismiss(restore: false) }
                if let fence = self.fence { fence.observeActivation(pid: pid); if fence.revoked { self.dismiss(restore: false) } }
            }
        }
    }
    func start() {
        applyAppearance(); installMenus()
        do { try installShortcuts(store.configuration) } catch { store.reportShortcutRegistrationFailure() }
        monitor = taskLifetime.start { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                guard self.store.desktopReviewAvailable else {
                    let reason = self.store.desktopReviewDiagnostic
                    Logger(subsystem: DesktopReviewScope.bundleIdentifier, category: "ReviewScope").error("Review disabled: \(reason, privacy: .public)")
                    self.store.refreshDesktopReviewAvailability()
                    self.dismiss(restore: false); self.hotkeys.invalidate(); return
                }
            }
        }
        openSettings()
    }
    func reopen() { openSettings() }
    func deactivate() {
        if fence == nil && !preparingTarget { dismiss(restore: false) }
    }
    func beginShutdown() {
        guard !stopping else { return }; stopping = true
        taskLifetime.close()
        monitor?.cancel(); capture?.cancel(); dismiss(restore: false); hotkeys.shutdown(); store.shutdown()
    }
    func prepareForQuit() async { await taskLifetime.shutdownAndWait(); await store.shutdownAndWait() }
    func shutdown() {
        beginShutdown()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
    private func installShortcuts(_ configuration: AppConfiguration) throws {
        guard store.desktopReviewAvailable, configuration.launcherShortcut == nil,
              Set(configuration.commandShortcuts.keys).isSubset(of: ["utility.clipboard"]) else { throw DesktopReviewError.unavailable }
        let entries = ShortcutPlan.entries(configuration)
        guard entries.allSatisfy({ $0.commandID == "utility.clipboard" }) else { throw DesktopReviewError.invalidScope }
        try hotkeys.replace(entries.map { entry in
            HotkeyDefinition(id: entry.id, binding: entry.binding) { [weak self] in
                guard let self, self.store.desktopReviewAvailable else { return }
                if self.panel?.isKeyWindow == true { self.dismiss(restore: true) }
                else { self.presentClipboard(activateTarget: false) }
            }
        })
    }
    private func applyAppearance() {
        switch store.configuration.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    @objc private func openSettings() {
        dismiss(restore: false)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 560, height: 590)
            window.title = AppL("Desktop review") + " — KeyDock"; window.isReleasedWhenClosed = false; window.delegate = self
            let controller = NSHostingController(rootView: DesktopReviewSettingsView(store: store) { [weak self] in self?.presentClipboard(activateTarget: true) })
            controller.sizingOptions = []; controller.sceneBridgingOptions = []
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 600, height: 720)); window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    private func refreshTitles() {
        settings?.title = AppL("Desktop review") + " — KeyDock"
        panel?.title = AppL("Clipboard history")
    }
    private func installMenus() {
        let menu = NSMenu(), appItem = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: AppL("Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator()); app.addItem(withTitle: AppL("Quit KeyDock"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app; menu.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: AppL("Edit"))
        edit.addItem(withTitle: AppL("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: AppL("Run current action"), action: #selector(commitAlternate), keyEquivalent: "\r").target = self
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        statusItem?.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: AppL("Desktop review"))
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: AppL("Settings…"), action: #selector(openSettings), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: AppL("Quit KeyDock"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem?.menu = statusMenu
    }
    @objc private func commitAlternate() {
        guard NSApp.keyWindow === panel, store.desktopReviewAvailable, KDTextInputState.permitsCurrentAction else { return }
        session.commitAlternate()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(commitAlternate) {
            return NSApp.keyWindow === panel && store.desktopReviewAvailable && KDTextInputState.permitsCurrentAction && session.canCommit && (session.preferences.primaryAction == .insert || session.canInsert)
        }
        return !store.isShuttingDown
    }
    private func frontIsTarget() -> Bool {
        guard scope.isCurrent, let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.processIdentifier == scope.targetIdentity.pid && app.launchDate == scope.targetIdentity.launchDate
    }
    private func presentClipboard(activateTarget: Bool) {
        guard store.desktopReviewAvailable else { return }
        dismiss(restore: false)
        let request = generation
        preparingTarget = activateTarget
        capture = taskLifetime.start { [weak self] in
            guard let self else { return }
            defer { if generation == request { preparingTarget = false } }
            if activateTarget {
                guard scope.activateTarget() else { return }
                for _ in 0..<20 {
                    if frontIsTarget() { break }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard generation == request, store.desktopReviewAvailable else { return }
                }
            }
            // 仅固定PID/birth；不读取其他应用的选区、窗口标题或剪贴板。
            guard frontIsTarget(), generation == request, !Task.isCancelled else { return }
            let identity = scope.targetIdentity
            let captured = await store.desktop.capturePasteTarget(identity)
            guard frontIsTarget(), generation == request, !Task.isCancelled, store.desktopReviewAvailable else { return }
            target = captured
            if panel == nil {
                let window = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.title = AppL("Clipboard history"); window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = true
                window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false; window.isFloatingPanel = true; window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.delegate = self; window.isMovableByWindowBackground = true
                window.contentView = KDLauncherSurface.make(root: ClipboardPanelView(store: store, session: session, dismiss: { [weak self] in self?.dismiss(restore: true) }), review: visual)
                window.onEscape = { [weak self] in self?.dismiss(restore: true) }; window.center(); panel = window
            }
            session.present(access: store.clipboardStore, returnTarget: identity, onMutation: { [weak self] in self?.store.refreshClipboard() })
            session.canInsert = captured != nil && store.desktop.clipboardInsertionAvailable
            session.targetName = identity.name
            NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil)
        }
    }
    private func dismiss(restore: Bool) {
        generation = UUID(); preparingTarget = false; capture?.cancel(); capture = nil; paste?.cancel(); paste = nil
        panel?.orderOut(nil); session.dismiss(); target = nil; fence = nil
        if restore, scope.isCurrent { _ = scope.activateTarget() }
    }
    private func insert(_ text: String, token: UUID) {
        guard store.desktopReviewAvailable, paste == nil, let target, scope.permits(target.identity), session.acceptsCommit(token) else { return }
        let request = generation
        let fence = ClipboardPasteActivationFence(ownPID: ProcessInfo.processInfo.processIdentifier, targetPID: target.identity.pid)
        self.fence = fence; panel?.orderOut(nil)
        paste = taskLifetime.start { [weak self] in
            guard let self else { return }
            do {
                try await store.insertClipboardText(text, target: target, isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.store.desktopReviewAvailable && self.generation == request && self.session.acceptsCommit(token) && !fence.revoked
                })
                if generation == request { dismiss(restore: false) }
            } catch {
                guard generation == request, !Task.isCancelled, !store.isShuttingDown else { return }
                paste = nil; self.target = nil; self.fence = nil; session.canInsert = false; session.reportInsertionFailure(); panel?.orderFrontRegardless()
            }
        }
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        KDSearchField.needsRestrictedEditor(client) ? editor : nil
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === panel { dismiss(restore: false) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel, fence == nil { dismiss(restore: false) }
    }
}
