import AppKit
import SwiftUI

public struct KDSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onAlternateSubmit: (() -> Void)?
    public init(text: Binding<String>, focusRequest: UUID, placeholder: String, onMove: @escaping (Int) -> Void, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void, onAlternateSubmit: (() -> Void)? = nil) {
        _text = text; self.focusRequest = focusRequest; self.placeholder = placeholder
        self.onMove = onMove; self.onSubmit = onSubmit; self.onCancel = onCancel
        self.onAlternateSubmit = onAlternateSubmit
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSTextField {
        let field = FocusedSearchField(); field.placeholderString = placeholder; field.font = .systemFont(ofSize: 22)
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    public func updateNSView(_ field: NSTextField, context: Context) {
        if context.coordinator.parent.focusRequest != focusRequest {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        context.coordinator.parent = self
        field.placeholderString = placeholder; field.setAccessibilityLabel(placeholder)
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    @MainActor public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KDSearchField
        init(_ parent: KDSearchField) { self.parent = parent }
        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // 输入法正在组合时，把 Return/Esc/方向键交回输入法。
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true, let alternate = parent.onAlternateSubmit { alternate() }
                else { parent.onSubmit() }
                return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

/// SwiftUI可能在window连接之前创建控件；不能依赖一次nil window的异步请求。
@MainActor private final class FocusedSearchField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }
}
