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
    let onToggleSelection: (() -> Void)?
    let acceptsExternalText: Bool
    public init(text: Binding<String>, focusRequest: UUID, placeholder: String, onMove: @escaping (Int) -> Void, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void, onAlternateSubmit: (() -> Void)? = nil, onToggleSelection: (() -> Void)? = nil, acceptsExternalText: Bool = true) {
        _text = text; self.focusRequest = focusRequest; self.placeholder = placeholder
        self.onMove = onMove; self.onSubmit = onSubmit; self.onCancel = onCancel
        self.onAlternateSubmit = onAlternateSubmit
        self.onToggleSelection = onToggleSelection
        self.acceptsExternalText = acceptsExternalText
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSTextField {
        let field = FocusedSearchField(); field.placeholderString = placeholder; field.font = .systemFont(ofSize: 22)
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = context.coordinator
        field.acceptsExternalText = acceptsExternalText
        field.setAccessibilityLabel(placeholder)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    public func updateNSView(_ field: NSTextField, context: Context) {
        if context.coordinator.parent.focusRequest != focusRequest {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        context.coordinator.parent = self
        (field as? FocusedSearchField)?.acceptsExternalText = acceptsExternalText
        field.placeholderString = placeholder; field.setAccessibilityLabel(placeholder)
        if !field.stringValue.utf8.elementsEqual(text.utf8), (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    @MainActor public static func needsRestrictedEditor(_ client: Any?) -> Bool {
        (client as? FocusedSearchField)?.acceptsExternalText == false
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
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, let toggle = parent.onToggleSelection { toggle() }
                else if selector == #selector(NSResponder.insertLineBreak(_:)) { return false }
                else if NSApp.currentEvent?.modifierFlags.contains(.command) == true, let alternate = parent.onAlternateSubmit { alternate() }
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
    var acceptsExternalText = true
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsExternalText ? super.draggingEntered(sender) : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsExternalText && super.performDragOperation(sender)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }
}

/// 必须由窗口的field-editor委托返回；只拦截外部传输，保留键入和输入法组合。
@MainActor public final class KDRestrictedFieldEditor: NSTextView {
    private var ownedStorage: NSTextStorage?
    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        // init(frame:textContainer:nil)不会建立文本网络；显式持有，避免查询和IME静默丢失。
        let storage = container == nil ? NSTextStorage() : nil
        let effective = container ?? NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        if let storage { let manager = NSLayoutManager(); storage.addLayoutManager(manager); manager.addTextContainer(effective) }
        super.init(frame: frameRect, textContainer: effective)
        ownedStorage = storage; isFieldEditor = true; unregisterDraggedTypes()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); isFieldEditor = true; unregisterDraggedTypes() }
    public override func paste(_ sender: Any?) {}
    public override func pasteAsPlainText(_ sender: Any?) {}
    public override func pasteAsRichText(_ sender: Any?) {}
    public override func readSelection(from pboard: NSPasteboard) -> Bool { false }
    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
}
