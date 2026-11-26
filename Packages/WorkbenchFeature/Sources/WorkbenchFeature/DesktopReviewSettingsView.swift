import SwiftUI
import KeyDockUI
import MacAdapters

/// 复用生产设置组件，但不构造任何通用执行设置或恢复入口。
public struct DesktopReviewSettingsView: View {
    @ObservedObject private var store: WorkbenchModel
    private let openClipboard: () -> Void
    @State private var loading = false
    public init(store: WorkbenchModel, openClipboard: @escaping () -> Void) {
        self.store = store; self.openClipboard = openClipboard
    }
    public var body: some View {
        Form {
            Section(L("Desktop review")) {
                Text(L("Synthetic clipboard history and its fixed companion only. Restart the session if its identity changes."))
                    .font(.callout).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Label(store.desktopReviewAvailable ? L("Review session available") : L("Review session expired"), systemImage: store.desktopReviewAvailable ? "checkmark.shield" : "exclamationmark.shield")
                }
                Button(L("Load synthetic history")) {
                    loading = true
                    Task { await store.loadDesktopReviewHistory(); loading = false }
                }.disabled(loading || !store.desktopReviewAvailable)
                Button(L("Open clipboard for synthetic target"), action: openClipboard).disabled(!store.desktopReviewAvailable)
                Button(L("Enable Accessibility")) { store.requestAccessibility() }.disabled(!store.desktopReviewAvailable)
            }
            Section(L("Appearance & language")) {
                Picker(L("Language"), selection: Binding(get: { store.configuration.language }, set: { store.setLanguage($0) })) {
                    Text(L("Follow System")).tag("system"); Text("English").tag("en"); Text("简体中文").tag("zh-Hans")
                }
                Picker(L("Appearance"), selection: Binding(get: { store.configuration.appearance }, set: { store.setAppearance($0) })) {
                    Text(L("Follow System")).tag("system"); Text(L("Light")).tag("light"); Text(L("Dark")).tag("dark")
                }
            }.disabled(!store.desktopReviewAvailable)
            Section(L("Clipboard shortcut")) {
                HotkeyRecorder(binding: Binding(get: { store.shortcut(for: "utility.clipboard") }, set: { store.setShortcut($0, for: "utility.clipboard") }), onRecording: { store.onShortcutRecordingChanged?($0) })
                    .disabled(!store.desktopReviewAvailable)
            }
            ClipboardBehaviorSettingsView(preferences: store.clipboardPreferences)
                .id(store.configuration.language).disabled(!store.desktopReviewAvailable)
            if !store.settingsNoticeMessage.rendered().isEmpty { KDInlineNotice(store.settingsNoticeMessage.rendered()) }
        }.formStyle(.grouped).frame(minWidth: 560, minHeight: 590)
            .environment(\.locale, KDLocalizer.locale)
    }
}

extension WorkbenchModel {
    public func loadDesktopReviewHistory() async {
        guard desktopReviewAvailable else { return }
        for text in ["Synthetic KeyDock clipboard insertion.\nExactly one explicit commit.", "合成剪贴板文本：快捷检索、选择与插入。", "https://example.com/keydock/synthetic"] {
            guard desktopReviewAvailable, !Task.isCancelled else { return }
            do { _ = try await clipboardStore.insert(text: text, source: "KeyDock Synthetic Review") }
            catch { settingsNoticeMessage = noticeKey("Operation failed"); return }
        }
        refreshClipboard()
    }
}
