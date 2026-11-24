import Combine
import Foundation
import MacAdapters

/// 独立面板只持有当前查询、选中项与一个正文；不共享工作区导航或恢复插入任务。
@MainActor public final class ClipboardPanelSession: ObservableObject {
    public let browser: ClipboardBrowserSession
    @Published public private(set) var selectedID: String?
    @Published public private(set) var focusRequest = UUID()
    @Published public private(set) var scrollRequest = UUID()
    @Published public private(set) var isCommitting = false
    @Published public var canInsert = false
    @Published public var targetName = ""
    @Published public var noticeMessage: LocalizedNotice = .none
    public var onInsert: (@MainActor (String, UUID) -> Void)?
    public var onCopy: (@MainActor (String) -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = UUID()
    private var visible = false
    private(set) var commitTask: Task<Void, Never>?

    public init(browser: ClipboardBrowserSession = ClipboardBrowserSession()) {
        self.browser = browser
        browser.$results.sink { [weak self] values in
            guard let self, self.visible else { return }
            let next = values.first(where: { $0.id == self.selectedID }) ?? values.first
            self.select(next)
        }.store(in: &subscriptions)
    }
    public var selection: ClipboardPreview? { browser.results.first { $0.id == selectedID } }
    public func acceptsCommit(_ token: UUID) -> Bool { visible && generation == token }
    public func reportInsertionFailure() {
        canInsert = false
        noticeMessage = noticeKey("Insertion was not sent. The original target, permission or clipboard changed. Copy the item or open history again.")
    }
    public func present(access: any ClipboardAccess, onMutation: @escaping @MainActor () -> Void) {
        invalidate(); visible = true; selectedID = nil; noticeMessage = .none
        browser.query = ""; browser.connect(to: access, onMutation: onMutation)
        focusRequest = UUID()
    }
    public func dismiss() {
        visible = false; invalidate(); browser.disconnect(); selectedID = nil
        canInsert = false; targetName = ""; noticeMessage = .none
    }
    public func editQuery(_ value: String) {
        let bounded = TaskTextLimits.prefix(value, maximumBytes: 4_096)
        guard bounded != browser.query else { return }
        invalidate(); noticeMessage = .none; browser.query = bounded
    }
    public func select(_ entry: ClipboardPreview?) {
        guard selectedID != entry?.id else { return }
        invalidate(); selectedID = entry?.id
        if let entry { browser.preview(entry) } else { browser.closePreview() }
    }
    public func move(_ delta: Int) {
        guard !browser.results.isEmpty else { return }
        let index = browser.results.firstIndex { $0.id == selectedID } ?? 0
        select(browser.results[min(max(index + delta, 0), browser.results.count - 1)])
        scrollRequest = UUID()
    }
    public func commit(insert: Bool) {
        guard visible, !isCommitting, let entry = selection else { return }
        guard !insert || canInsert else {
            noticeMessage = noticeKey("Insertion needs Accessibility permission and an unchanged text target. You can still copy the item.")
            return
        }
        let request = generation
        isCommitting = true
        commitTask = Task { [weak self] in
            guard let self else { return }
            // 提交时重新按ID读取，不能使用可能已经过期的预览正文。
            await browser.copy(entry) { [weak self] text in
                guard let self, !Task.isCancelled, self.visible, self.generation == request, self.selectedID == entry.id else { return }
                if insert { self.onInsert?(text, request) } else { self.onCopy?(text) }
            }
            if generation == request { isCommitting = false }
        }
    }
    private func invalidate() {
        generation = UUID(); commitTask?.cancel(); commitTask = nil; isCommitting = false
    }
}
