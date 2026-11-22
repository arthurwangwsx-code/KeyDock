import AppKit
import SwiftUI

public struct KDSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    public init(text: Binding<String>, focusRequest: UUID, placeholder: String, onMove: @escaping (Int) -> Void, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _text = text; self.focusRequest = focusRequest; self.placeholder = placeholder
        self.onMove = onMove; self.onSubmit = onSubmit; self.onCancel = onCancel
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(); field.placeholderString = placeholder; field.font = .systemFont(ofSize: 22)
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
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
