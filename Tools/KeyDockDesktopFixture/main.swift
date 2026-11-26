import AppKit

/// 专供原生UI验收的合成宿主；剪贴板仅响应用户的标准编辑动作，无采集、文件或网络。
@main @MainActor enum KeyDockDesktopFixture {
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class FixtureEditor: NSTextView {
    private(set) var pasteRequests = 0
    var didPaste: ((Int) -> Void)?

    override func paste(_ sender: Any?) {
        pasteRequests += 1
        super.paste(sender)
        didPaste?(pasteRequests)
    }
}

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    #if KEYDOCK_DESKTOP_REVIEW_FIXTURE
    private var refuseQuit = false
    #else
    private var refuseQuit = true
    #endif
    private var quitRequests = 0
    private var labels: [NSTextField] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit KeyDock Desktop Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        for (index, name) in ["A", "B", "C"].enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 180 + index * 130, y: 180 + index * 80, width: 500, height: 330), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "KeyDock Synthetic Window " + name
            window.isReleasedWhenClosed = false
            let title = NSTextField(labelWithString: "Synthetic window " + name)
            title.font = .systemFont(ofSize: 24, weight: .semibold)
            let editor = FixtureEditor(frame: NSRect(x: 0, y: 0, width: 430, height: 100))
            editor.string = "Synthetic KeyDock acceptance text. No personal content.\nWindow " + name + " — clipboard insertion target."
            editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            editor.isRichText = false
            let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true
            scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
            let quitToggle = NSButton(checkboxWithTitle: "Hold normal quit requests for review", target: self, action: #selector(toggleQuit(_:)))
            quitToggle.state = refuseQuit ? .on : .off
            let status = NSTextField(labelWithString: "Normal quit requests: 0"); labels.append(status)
            let pasteStatus = NSTextField(labelWithString: "Window " + name + " paste requests: 0")
            pasteStatus.setAccessibilityIdentifier("fixture-paste-count-" + name)
            editor.didPaste = { count in
                pasteStatus.stringValue = "Window " + name + " paste requests: " + String(count)
            }
            let stack = NSStackView(views: [title, scroll, pasteStatus, quitToggle, status])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(stack)
            if let content = window.contentView {
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            }
            windows.append(window); window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
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
