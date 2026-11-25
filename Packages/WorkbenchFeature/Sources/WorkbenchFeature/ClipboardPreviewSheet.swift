import AppKit
import SwiftUI
import KeyDockUI

/// 明确打开的单项详情；完整正文不会进入列表或每行 View body 的过滤路径。
struct ClipboardPreviewSheet: View {
    @ObservedObject var session: ClipboardBrowserSession
    let writer: @MainActor (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Preview")).font(.title3.bold())
                Spacer()
                Button(L("Copy")) { Task { await session.copyPreview(perform: writer) } }.disabled(session.previewText == nil)
                Button(L("Close")) { session.closePreview() }.keyboardShortcut(.cancelAction)
            }
            if !session.notice.isEmpty { KDInlineNotice(session.notice) }
            if session.isPreviewLoading {
                ProgressView(L("Loading preview…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text = session.previewText {
                ClipboardReadOnlyText(text: text)
            } else {
                Text(L("No output")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(20).frame(width: 640, height: 480)
    }
}

typealias ClipboardReadOnlyText = ReadOnlyTextPreview

struct ReadOnlyTextPreview: NSViewRepresentable {
    let text: String
    var transparent = false
    var accessibilityLabel: String? = nil
    var monospaced = false
    var pointSize: CGFloat? = nil
    private var textFont: NSFont {
        monospaced ? .monospacedSystemFont(ofSize: pointSize ?? 11, weight: .regular) : .systemFont(ofSize: pointSize ?? 13)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = !transparent
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false; view.isSelectable = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.allowsNonContiguousLayout = true
        view.font = textFont
        view.backgroundColor = .textBackgroundColor
        view.drawsBackground = !transparent
        view.setAccessibilityLabel(accessibilityLabel ?? L("Preview"))
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.setAccessibilityLabel(accessibilityLabel ?? L("Preview"))
        if view.font != textFont { view.font = textFont }
        Self.synchronizeText(text, in: view)
    }
    static func synchronizeText(_ text: String, in view: NSTextView) {
        // 规范等价不代表同一份字节正文；同时避免无变化刷新重置用户选区。
        if !view.string.utf8.elementsEqual(text.utf8) { view.string = text }
    }
}
