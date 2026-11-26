import AppKit
import SwiftUI
import KeyDockUI
import MacAdapters
import CommandCore

struct ClipboardEmptyQueryView: View {
    let outcome: ClipboardQueryOutcome
    var body: some View {
        KDEmptyState(symbol: "clipboard",
            title: outcome == .emptyHistory ? L("No clipboard items") : L("No matching clipboard items"),
            detail: outcome == .emptyHistory ? L("Recording is optional. Sensitive marked content is skipped.") : L("Try another word or clear the search."))
    }
}

public struct ClipboardPanelView: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.kdVisualReview) private var review
    private var highContrast: Bool { review.increasesContrast(system: contrast) }
    private var opaqueSurface: Bool { review.usesOpaqueSurfaces(system: reduceTransparency) }
    @ObservedObject private var store: WorkbenchModel
    @ObservedObject private var session: ClipboardPanelSession
    @ObservedObject private var browser: ClipboardBrowserSession
    @ObservedObject private var preferences: ClipboardPanelPreferences
    @State private var pointer = NSEvent.mouseLocation
    private let dismiss: () -> Void
    public init(store: WorkbenchModel, session: ClipboardPanelSession, dismiss: @escaping () -> Void) {
        self.store = store; self.session = session; browser = session.browser; preferences = session.preferences; self.dismiss = dismiss
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "clipboard").font(.system(size: 23, weight: .light)).foregroundStyle(.secondary)
                KDSearchField(text: Binding(get: { browser.query }, set: session.editQuery), focusRequest: session.focusRequest,
                              placeholder: L("Search clipboard history"), onMove: session.move,
                              onSubmit: session.commitPrimary, onCancel: dismiss,
                              onAlternateSubmit: session.commitAlternate, onToggleSelection: session.toggleCurrent,
                              acceptsExternalText: !store.isDesktopReview).frame(height: 34)
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
                KDKeyboardHint("⇧↩", label: L("Select for merge"))
                Spacer()
                Button { session.commit(insert: false) } label: { KDKeyboardHint(preferences.primaryAction == .copy ? "↩" : "⌘↩", label: L("Copy")) }
                    .buttonStyle(.plain).disabled(!session.canCommit)
                Button { session.commit(insert: true) } label: { KDKeyboardHint(preferences.primaryAction == .insert ? "↩" : "⌘↩", label: L("Insert")) }
                    .buttonStyle(.plain).disabled(!session.canCommit || !session.canInsert)
            }.padding(.horizontal, 20).frame(height: 48)
        }.frame(width: 860, height: 540)
            .environment(\.locale, KDLocalizer.locale)
            .onReceive(store.$clipboardRevision.dropFirst()) { _ in session.refresh() }
    }
    private var history: some View {
        VStack(spacing: 0) {
            KDResultSectionHeader(L("Clipboard history"), count: browser.results.count)
            if browser.queryOutcome == .failed {
                Button(L("Refresh")) { session.refresh() }.frame(maxHeight: .infinity)
            } else if let outcome = browser.queryOutcome, outcome.isEmpty {
                VStack(spacing: 12) {
                    ClipboardEmptyQueryView(outcome: outcome)
                    if outcome == .emptyHistory && !store.configuration.clipboardEnabled {
                        Button(L("Enable clipboard history")) { store.setClipboardRecording(true) }.disabled(!store.allowContextCapture)
                    }
                }.frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(browser.results) { entry in
                                HStack(spacing: 0) {
                                    Button { session.toggleMark(entry) } label: {
                                        Image(systemName: session.markedItems.contains(where: { $0.id == entry.id }) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 17)).frame(width: 30, height: 56)
                                    }.buttonStyle(.plain).disabled(session.isCommitting)
                                        .accessibilityLabel((session.markedItems.contains(where: { $0.id == entry.id }) ? L("Remove from merge") : L("Add to merge")) + ": " + entry.preview)
                                    Button { session.select(entry) } label: { row(entry) }.buttonStyle(.plain)
                                        .accessibilityLabel(entry.preview)
                                        .accessibilityAddTraits(session.selectedID == entry.id ? .isSelected : [])
                                        .onHover { inside in
                                            let now = NSEvent.mouseLocation
                                            if inside && !session.isCommitting && now != pointer { pointer = now; session.select(entry) }
                                        }
                                }.id(entry.id)
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
                    Text(ByteCountFormatStyle(style: .file, locale: KDLocalizer.locale).format(Int64(entry.byteCount)))
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(session.selectedID == entry.id ? Color.accentColor.opacity(highContrast ? 0.28 : 0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(session.selectedID == entry.id ? Color.accentColor.opacity(highContrast ? 0.9 : 0.32) : .clear, lineWidth: highContrast ? 1.5 : 1))
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.markedItems.isEmpty ? L("Preview") : L("Merged preview")).font(.headline)
                Spacer()
                if session.markedItems.isEmpty, let entry = session.selection {
                    KDIconButton(entry.pinned ? "pin.slash" : "pin", label: entry.pinned ? L("Unpin item") : L("Pin item")) { Task { await browser.pin(entry) } }
                    KDIconButton("trash", label: L("Delete"), role: .destructive) { Task { await browser.delete(entry) } }
                }
            }
            if !session.markedItems.isEmpty { mergeControls }
            if browser.isPreviewLoading || session.isCompositionLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let text = session.previewText {
                ClipboardReadOnlyText(text: text, transparent: true)
                    .background(Color(nsColor: .textBackgroundColor).opacity(opaqueSurface ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            else { Text(L("Select an item to preview its full text.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if session.canInsert {
                Label(session.targetName, systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(.secondary)
                Text(L("Insert sends the merged plain text once to the original app. The text stays on the clipboard.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("Insertion needs Accessibility permission and an unchanged text target. You can still copy the item.")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
    }
    private var mergeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Selected items") + " · \(session.markedItems.count)/20").font(.caption.weight(.medium))
                Spacer()
                Picker(L("Separator"), selection: $preferences.separator) {
                    ForEach(ClipboardSeparator.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 120).accessibilityLabel(L("Separator"))
                Button(L("Clear selection")) { session.clearMarks() }
            }.controlSize(.small)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(session.markedItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                            Text(item.preview.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            KDIconButton("arrow.up", label: L("Move earlier") + " " + (index + 1).formatted()) { session.moveMark(id: item.id, delta: -1) }.disabled(index == 0)
                            KDIconButton("arrow.down", label: L("Move later") + " " + (index + 1).formatted()) { session.moveMark(id: item.id, delta: 1) }.disabled(index == session.markedItems.count - 1)
                            KDIconButton("minus.circle", label: L("Remove from merge") + " " + (index + 1).formatted()) { session.removeMark(id: item.id) }
                        }
                    }
                }
            }.frame(maxHeight: 90)
            Text(L("Selection order · up to 20 items · 1 MiB including separators")).font(.caption2).foregroundStyle(.secondary)
        }.disabled(session.isCommitting)
    }
}
