import AppKit

/// 专供人工/原生UI验收的合成宿主，没有剪贴板、文件或网络入口。
@main @MainActor enum KeyDockDesktopFixture {
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var refuseQuit = true
    private var quitRequests = 0
    private var labels: [NSTextField] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit KeyDock Desktop Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        for (index, name) in ["A", "B", "C"].enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 180 + index * 130, y: 180 + index * 80, width: 500, height: 330), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "KeyDock Synthetic Window " + name
            window.isReleasedWhenClosed = false
            let title = NSTextField(labelWithString: "Synthetic window " + name)
            title.font = .systemFont(ofSize: 24, weight: .semibold)
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 430, height: 100))
            editor.string = "Synthetic KeyDock acceptance text. No personal content.\nWindow " + name + " — clipboard insertion target."
            editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            editor.isRichText = false
            let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true
            scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
            let quitToggle = NSButton(checkboxWithTitle: "Hold normal quit requests for review", target: self, action: #selector(toggleQuit(_:)))
            quitToggle.state = .on
            let status = NSTextField(labelWithString: "Normal quit requests: 0"); labels.append(status)
            let stack = NSStackView(views: [title, scroll, quitToggle, status])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(stack)
            if let content = window.contentView {
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            }
            windows.append(window); window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleQuit(_ sender: NSButton) {
        refuseQuit = sender.state == .on
        for window in windows {
            for view in (window.contentView?.subviews.first as? NSStackView)?.arrangedSubviews ?? [] {
                if let button = view as? NSButton { button.state = refuseQuit ? .on : .off }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitRequests += 1
        for label in labels { label.stringValue = "Normal quit requests: \(quitRequests)" }
        return refuseQuit ? .terminateCancel : .terminateNow
    }
}
