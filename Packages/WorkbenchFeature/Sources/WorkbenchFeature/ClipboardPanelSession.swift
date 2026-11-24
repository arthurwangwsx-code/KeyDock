import Combine
import Foundation
import MacAdapters
import CommandCore

/// 独立面板只持有当前查询、选中项与一个正文；不共享工作区导航或恢复插入任务。
@MainActor public final class ClipboardPanelSession: ObservableObject {
    public let browser: ClipboardBrowserSession
    public let preferences: ClipboardPanelPreferences
    @Published public private(set) var selectedID: String?
    @Published public private(set) var focusRequest = UUID()
    @Published public private(set) var scrollRequest = UUID()
    @Published public private(set) var isCommitting = false
    @Published public private(set) var markedItems: [ClipboardPreview] = []
    @Published public private(set) var composition: ClipboardComposition?
    @Published public private(set) var isCompositionLoading = false
    @Published public var canInsert = false
    @Published public var targetName = ""
    public private(set) var returnTarget: TargetIdentity?
    @Published public var noticeMessage: LocalizedNotice = .none
    public var onInsert: (@MainActor (String, UUID) -> Void)?
    public var onCopy: (@MainActor (String) throws -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = UUID()
    private var visible = false
    private(set) var commitTask: Task<Void, Never>?
    private(set) var compositionTask: Task<Void, Never>?
    private var compositionGeneration = UUID()

    public init(browser: ClipboardBrowserSession = ClipboardBrowserSession(), preferences: ClipboardPanelPreferences = ClipboardPanelPreferences()) {
        self.browser = browser; self.preferences = preferences
        browser.$results.sink { [weak self] values in
            guard let self, self.visible else { return }
            let next = values.first(where: { $0.id == self.selectedID }) ?? values.first
            self.select(next)
        }.store(in: &subscriptions)
        preferences.$revision.dropFirst().sink { [weak self] _ in
            guard let self, self.visible else { return }
            self.invalidate(); self.reloadComposition()
        }.store(in: &subscriptions)
    }
    public var selection: ClipboardPreview? { browser.results.first { $0.id == selectedID } }
    public var hasContent: Bool { !markedItems.isEmpty || selection != nil }
    public var canCommit: Bool { hasContent && !isCommitting && (markedItems.isEmpty || composition != nil) }
    public var previewText: String? { markedItems.isEmpty ? browser.previewText : composition?.text }
    public func commitPrimary() { commit(insert: preferences.primaryAction == .insert) }
    public func commitAlternate() { commit(insert: preferences.primaryAction.alternate == .insert) }
    public func toggleCurrent() { if let selection { toggleMark(selection) } }
    public func toggleMark(_ entry: ClipboardPreview) {
        guard visible, !isCommitting else { return }
        if let index = markedItems.firstIndex(where: { $0.id == entry.id }) { markedItems.remove(at: index) }
        else {
            guard markedItems.count < ClipboardComposition.maximumItems else { noticeMessage = noticeKey("Select up to 20 items to merge."); return }
            markedItems.append(entry)
        }
        invalidate(); reloadComposition()
    }
    public func removeMark(id: String) {
        guard let entry = markedItems.first(where: { $0.id == id }) else { return }
        toggleMark(entry)
    }
    public func moveMark(id: String, delta: Int) {
        guard !isCommitting, let index = markedItems.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + delta
        guard markedItems.indices.contains(destination) else { return }
        markedItems.swapAt(index, destination); invalidate(); reloadComposition()
    }
    public func clearMarks() {
        guard !isCommitting else { return }
        markedItems = []; invalidate(); reloadComposition()
    }
    public func refresh() { invalidate(); browser.refresh(); reloadComposition() }
    public func acceptsCommit(_ token: UUID) -> Bool { visible && generation == token }
    public func reportInsertionFailure() {
        canInsert = false
        noticeMessage = noticeKey("Insertion was not sent. The original target, permission or clipboard changed. Copy the item or open history again.")
    }
    public func present(access: any ClipboardAccess, returnTarget: TargetIdentity? = nil, onMutation: @escaping @MainActor () -> Void) {
        invalidate(); resetComposition(); markedItems = []; visible = true; selectedID = nil; noticeMessage = .none
        self.returnTarget = returnTarget
        browser.query = ""; browser.connect(to: access, onMutation: onMutation)
        focusRequest = UUID()
    }
    public func dismiss() {
        visible = false; invalidate(); resetComposition(); markedItems = []; browser.disconnect(); selectedID = nil
        canInsert = false; targetName = ""; noticeMessage = .none
        returnTarget = nil
    }
    public func editQuery(_ value: String) {
        let bounded = TaskTextLimits.prefix(value, maximumBytes: 4_096)
        guard bounded != browser.query else { return }
        invalidate(); noticeMessage = .none; browser.query = bounded
        reloadComposition()
    }
    public func select(_ entry: ClipboardPreview?) {
        guard selectedID != entry?.id else { return }
        invalidate(); selectedID = entry?.id
        if markedItems.isEmpty, let entry { browser.preview(entry) } else { browser.closePreview() }
    }
    public func move(_ delta: Int) {
        guard !browser.results.isEmpty else { return }
        let index = browser.results.firstIndex { $0.id == selectedID } ?? 0
        select(browser.results[min(max(index + delta, 0), browser.results.count - 1)])
        scrollRequest = UUID()
    }
    public func commit(insert: Bool) {
        guard visible, canCommit else { return }
        guard !insert || canInsert else {
            noticeMessage = noticeKey("Insertion needs Accessibility permission and an unchanged text target. You can still copy the item.")
            return
        }
        let request = generation
        let approved = composition
        let entry = selection
        isCommitting = true
        commitTask = Task { [weak self] in
            guard let self else { return }
            if let approved, !markedItems.isEmpty {
                do {
                    let current = try await browser.composition(ids: approved.ids, separator: approved.separator)
                    guard acceptsCommit(request), !Task.isCancelled else { return }
                    guard current == approved else {
                        composition = current; noticeMessage = noticeKey("Selected text changed. Review the merged preview before submitting again.")
                        isCommitting = false; return
                    }
                    perform(current.text, insert: insert, request: request)
                } catch {
                    if acceptsCommit(request), !Task.isCancelled { composition = nil; noticeMessage = compositionNotice(error) }
                }
                if generation == request { isCommitting = false }
                return
            }
            guard let entry else { if generation == request { isCommitting = false }; return }
            // 提交时重新按ID读取，不能使用可能已经过期的预览正文。
            await browser.copy(entry) { [weak self] text in
                guard let self, !Task.isCancelled, self.visible, self.generation == request, self.selectedID == entry.id else { return }
                self.perform(text, insert: insert, request: request)
            }
            if generation == request { isCommitting = false }
        }
    }
    private func perform(_ text: String, insert: Bool, request: UUID) {
        if insert { onInsert?(text, request) }
        else {
            do { try onCopy?(text) }
            catch { noticeMessage = noticeKey("Copy could not be confirmed. The clipboard may have changed. Review before trying again.") }
        }
    }
    private func compositionNotice(_ error: any Error) -> LocalizedNotice {
        switch error {
        case ClipboardCompositionError.tooLarge: noticeKey("Merged text exceeds 1 MiB. Remove an item or choose a shorter separator.")
        case ClipboardCompositionError.missingItem: noticeKey("A selected item is no longer available. Remove it or select the items again.")
        default: noticeKey("The merged preview could not be loaded. Review the selection and try again.")
        }
    }
    private func resetComposition() {
        compositionGeneration = UUID(); compositionTask?.cancel(); compositionTask = nil
        composition = nil; isCompositionLoading = false
    }
    private func reloadComposition() {
        resetComposition(); noticeMessage = .none
        guard visible, !markedItems.isEmpty else {
            if visible, let selection { browser.preview(selection) }; return
        }
        browser.closePreview()
        let request = compositionGeneration, ids = markedItems.map(\.id), separator = preferences.separator
        isCompositionLoading = true
        compositionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await browser.composition(ids: ids, separator: separator)
                guard !Task.isCancelled, visible, compositionGeneration == request else { return }
                composition = value
            } catch {
                guard !Task.isCancelled, visible, compositionGeneration == request else { return }
                if !(error is CancellationError) { noticeMessage = compositionNotice(error) }
            }
            if compositionGeneration == request { isCompositionLoading = false }
        }
    }
    private func invalidate() {
        generation = UUID(); commitTask?.cancel(); commitTask = nil; isCommitting = false
    }
}
