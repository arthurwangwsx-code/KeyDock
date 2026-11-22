import AppKit
import SwiftUI
import WorkbenchFeature
import MacAdapters

@main
@MainActor enum KeyDockApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: WorkbenchModel?
    private var panel: LauncherPanel?
    private var statusItem: NSStatusItem?
    private let hotkeys = HotkeyCenter()
    private var terminating = false
    private var presentationGeneration = UUID()
    private var captureTask: Task<Void, Never>?
    private var originalIdentity: TargetIdentity?
    private let safeSmoke = ProcessInfo.processInfo.arguments.contains("--safe-smoke") || (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true)
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let model = try WorkbenchModel(dataDirectory: safeSmoke ? FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Smoke") : nil, allowContextCapture: !safeSmoke); self.model = model
            let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "KeyDock"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
            panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 800, height: 600); panel.delegate = self
            panel.contentView = NSHostingView(rootView: WorkbenchView(model: model))
            panel.onEscape = { [weak self] in self?.dismiss(restore: true) }
            self.panel = panel
            model.onDismiss = { [weak self] in self?.dismiss(restore: $0) }
            model.onShortcutConfigurationChanged = { [weak self] in self?.installShortcuts() }
            model.onShortcutRecordingChanged = { [weak self] recording in
                guard let self else { return }
                if recording { self.hotkeys.suspend() }
                else {
                    do { try self.hotkeys.resume() }
                    catch { model.message = String(localized: "Shortcut could not be registered. It may be used by macOS or another application.") }
                }
            }
            createStatusItem(); installShortcuts(); present()
        } catch {
            let alert = NSAlert(); alert.messageText = "KeyDock"; alert.informativeText = String(localized: "Local data could not be opened. Existing files were preserved."); alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "KeyDock")
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Open KeyDock"), action: #selector(openLauncher), keyEquivalent: ""); open.target = self; menu.addItem(open)
        let tasks = NSMenuItem(title: String(localized: "Running tasks"), action: #selector(openTasks), keyEquivalent: ""); tasks.target = self; menu.addItem(tasks)
        let settings = NSMenuItem(title: String(localized: "Settings"), action: #selector(openSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit KeyDock"), action: #selector(quitApplication), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu; statusItem = item
        let main = NSMenu()
        let applicationItem = NSMenuItem(title: "KeyDock", action: nil, keyEquivalent: "")
        applicationItem.submenu = menu.copy() as? NSMenu
        main.addItem(applicationItem); NSApp.mainMenu = main
    }
    @objc private func openLauncher() { present() }
    @objc private func openTasks() { present(); model?.section = .tasks }
    @objc private func openSettings() { present(); model?.section = .settings }
    @objc private func quitApplication() { NSApp.terminate(nil) }
    private func present(commandID: String? = nil) {
        guard let panel, let model else { return }
        presentationGeneration = UUID(); let generation = presentationGeneration
        captureTask?.cancel()
        let identity = safeSmoke ? nil : model.desktop.frontmostTarget()
        originalIdentity = identity
        model.show(target: nil)
        if !panel.isVisible {
            let location = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main
            if let screen {
                var frame = panel.frame
                frame.origin.x = screen.visibleFrame.midX - frame.width / 2
                frame.origin.y = screen.visibleFrame.midY - frame.height / 2 + 55
                panel.setFrame(frame, display: false)
            }
        }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        if let identity {
            captureTask = Task { [weak self] in
                guard let self else { return }
                let snapshot = await model.desktop.captureTarget(identity)
                guard !Task.isCancelled, self.presentationGeneration == generation, panel.isVisible else { return }
                model.target = snapshot
                if let commandID { model.performCommand(id: commandID) }
            }
        } else if let commandID { model.performCommand(id: commandID) }
    }
    private func dismiss(restore: Bool) {
        presentationGeneration = UUID(); captureTask?.cancel()
        panel?.orderOut(nil)
        if restore {
            if let target = model?.target { model?.desktop.restore(target) }
            else if let originalIdentity { model?.desktop.restore(identity: originalIdentity) }
        }
    }
    private func installShortcuts() {
        guard let model else { return }
        var next: [UInt32: (HotkeyBinding, String?)] = [:]
        if let binding = model.configuration.launcherShortcut { next[1] = (binding, nil) }
        for (commandID, binding) in model.directShortcuts {
            var hash: UInt32 = 2166136261
            for byte in commandID.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
            hash = max(2, hash)
            guard next[hash] == nil else { model.message = String(localized: "Shortcut identifiers conflict; choose a different shortcut"); continue }
            next[hash] = (binding, commandID)
        }
        for id in hotkeys.configuredIDs.subtracting(next.keys) { try? hotkeys.set(id: id, binding: nil, action: {}) }
        for (id, entry) in next {
            do {
                try hotkeys.set(id: id, binding: entry.0) { [weak self] in
                    guard let self else { return }
                    if let command = entry.1 { self.present(commandID: command) }
                    else if self.panel?.isVisible == true, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { self.dismiss(restore: true) }
                    else { self.present() }
                }
            } catch { model.message = String(localized: "Shortcut could not be registered. It may be used by macOS or another application.") }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(restore: true); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        present()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await model?.shutdownAndWait(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { hotkeys.shutdown(); model?.shutdown() }
}
