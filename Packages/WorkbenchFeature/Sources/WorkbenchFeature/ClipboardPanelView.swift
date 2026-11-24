import AppKit
import SwiftUI
import KeyDockUI
import MacAdapters

public struct ClipboardPanelView: View {
    @ObservedObject private var store: WorkbenchModel
    @ObservedObject private var session: ClipboardPanelSession
    @ObservedObject private var browser: ClipboardBrowserSession
    @State private var pointer = NSEvent.mouseLocation
    private let dismiss: () -> Void
    public init(store: WorkbenchModel, session: ClipboardPanelSession, dismiss: @escaping () -> Void) {
        self.store = store; self.session = session; browser = session.browser; self.dismiss = dismiss
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "clipboard").font(.system(size: 23, weight: .light)).foregroundStyle(.secondary)
                KDSearchField(text: Binding(get: { browser.query }, set: session.editQuery), focusRequest: session.focusRequest,
                              placeholder: L("Search clipboard history"), onMove: session.move,
                              onSubmit: { session.commit(insert: true) }, onCancel: dismiss,
                              onAlternateSubmit: { session.commit(insert: false) }).frame(height: 34)
                if browser.isSearching || session.isCommitting { ProgressView().controlSize(.small) }
                KDKeycap("esc")
            }.padding(.horizontal, 22).frame(height: 76)
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                history.frame(width: 334)
                Divider().opacity(0.4)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !session.noticeMessage.rendered().isEmpty { KDInlineNotice(session.noticeMessage.rendered()).lineLimit(3) }
            if !browser.notice.isEmpty { KDInlineNotice(browser.notice).lineLimit(2) }
            if !store.clipboardCaptureNotice.isEmpty { KDInlineNotice(store.clipboardCaptureNotice).lineLimit(2) }
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                KDIconButton("gearshape", label: L("Clipboard privacy")) { store.onOpenSettings?(.clipboard) }
                KDIconButton("keyboard", label: L("Clipboard shortcut")) { store.onOpenSettings?(.shortcuts) }
                Text(L("Plain text")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { session.commit(insert: false) } label: { KDKeyboardHint("⌘↩", label: L("Copy")) }
                    .buttonStyle(.plain).disabled(session.selection == nil || session.isCommitting)
                Button { session.commit(insert: true) } label: { KDKeyboardHint("↩", label: L("Insert")) }
                    .buttonStyle(.plain).disabled(session.selection == nil || session.isCommitting)
            }.padding(.horizontal, 20).frame(height: 48)
        }.frame(width: 860, height: 540)
            .environment(\.locale, KDLocalizer.locale)
            .onReceive(store.$clipboardRevision.dropFirst()) { _ in browser.refresh() }
    }
    private var history: some View {
        VStack(spacing: 0) {
            KDResultSectionHeader(L("Clipboard history"), count: browser.results.count)
            if browser.results.isEmpty && !browser.isSearching {
                VStack(spacing: 12) {
                    KDEmptyState(symbol: "clipboard", title: L("No clipboard items"), detail: browser.query.isEmpty ? L("Recording is optional. Sensitive marked content is skipped.") : L("Try another word or clear the search."))
                    if !store.configuration.clipboardEnabled {
                        Button(L("Enable clipboard history")) { store.setClipboardRecording(true) }.disabled(!store.allowContextCapture)
                    }
                }.frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(browser.results) { entry in
                                Button { session.select(entry) } label: { row(entry) }.buttonStyle(.plain)
                                    .id(entry.id).accessibilityLabel(entry.preview)
                                    .accessibilityAddTraits(session.selectedID == entry.id ? .isSelected : [])
                                    .onHover { inside in
                                        let now = NSEvent.mouseLocation
                                        if inside && now != pointer { pointer = now; session.select(entry) }
                                    }
                            }
                        }.padding(.horizontal, 10).padding(.bottom, 10)
                    }.onChange(of: session.scrollRequest) { _, _ in
                        pointer = NSEvent.mouseLocation
                        if let id = session.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }
    private func row(_ entry: ClipboardPreview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.pinned ? "pin.fill" : "text.alignleft").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.preview.replacingOccurrences(of: "\n", with: " ")).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(entry.createdAt, style: .relative)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(session.selectedID == entry.id ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(session.selectedID == entry.id ? Color.accentColor.opacity(0.32) : .clear))
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Preview")).font(.headline)
                Spacer()
                if let entry = session.selection {
                    KDIconButton(entry.pinned ? "pin.slash" : "pin", label: entry.pinned ? L("Unpin item") : L("Pin item")) { Task { await browser.pin(entry) } }
                    KDIconButton("trash", label: L("Delete"), role: .destructive) { Task { await browser.delete(entry) } }
                }
            }
            if browser.isPreviewLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let text = browser.previewText {
                ClipboardReadOnlyText(text: text, transparent: true)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            else { Text(L("Select an item to preview its full text.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if session.canInsert {
                Label(session.targetName, systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(.secondary)
                Text(L("Return inserts into the original app. The selected plain text stays on the clipboard.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("Insertion needs Accessibility permission and an unchanged text target. You can still copy the item.")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
    }
}
