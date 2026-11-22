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

private struct ClipboardReadOnlyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false; view.isSelectable = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.allowsNonContiguousLayout = true
        view.font = .systemFont(ofSize: 13)
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel(L("Preview"))
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.setAccessibilityLabel(L("Preview"))
        if view.string != text { view.string = text }
    }
}
