import Combine
import Foundation
import MacAdapters
import CommandCore

/// 查询/操作共享同一个数据库 actor；窗口只拥有轻量预览和一个显式打开的正文。
public protocol ClipboardAccess: Sendable {
    func searchPreviews(query: String) async throws -> [ClipboardPreview]
    func text(id: String) async throws -> String?
    func setPinned(id: String, pinned: Bool) async throws
    func delete(id: String) async throws
    func clear() async throws
}

extension ClipboardStore: ClipboardAccess {}

public protocol ClipboardCompositionAccess: ClipboardAccess {
    func composition(ids: [String], separator: ClipboardSeparator) async throws -> ClipboardComposition
}
extension ClipboardStore: ClipboardCompositionAccess {}

@MainActor public final class ClipboardBrowserSession: ObservableObject {
    @Published public var query = "" {
        didSet { if query != oldValue { closePreview(); refresh() } }
    }
    @Published public private(set) var results: [ClipboardPreview] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var noticeMessage: LocalizedNotice = .none
    public var notice: String { noticeMessage.rendered() }
    @Published public private(set) var previewedID: String?
    @Published public private(set) var previewText: String?
    @Published public private(set) var isPreviewLoading = false
    private var access: (any ClipboardAccess)?
    private var generation = UUID()
    private var previewGeneration = UUID()
    private var didMutate: @MainActor () -> Void = {}
    private(set) var searchTask: Task<Void, Never>?
    private(set) var previewTask: Task<Void, Never>?

    public init(access: (any ClipboardAccess)? = nil) { self.access = access }

    public func connect(to access: any ClipboardAccess, onMutation: @escaping @MainActor () -> Void = {}) {
        self.access = access; didMutate = onMutation
        refresh()
    }

    public func disconnect() {
        generation = UUID(); searchTask?.cancel(); searchTask = nil
        results = []; isSearching = false
        closePreview(); access = nil; didMutate = {}
    }

    public func refresh() {
        generation = UUID(); let requestID = generation, requestQuery = query
        searchTask?.cancel(); results = []; noticeMessage = .none
        guard let access else { isSearching = false; return }
        isSearching = true
        searchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let values = try await access.searchPreviews(query: requestQuery)
                guard let self, !Task.isCancelled, self.generation == requestID, self.query == requestQuery else { return }
                self.results = values; self.isSearching = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == requestID else { return }
                self.isSearching = false; self.noticeMessage = noticeKey("Clipboard storage failed")
            }
        }
        // 已打开详情按 ID 重新校验；删除或过期后不能继续显示旧正文。
        if let id = previewedID { loadPreview(id: id) }
    }

    public func preview(_ entry: ClipboardPreview) { loadPreview(id: entry.id) }

    private func loadPreview(id: String) {
        previewGeneration = UUID(); let requestID = previewGeneration
        previewTask?.cancel(); previewedID = id; previewText = nil; noticeMessage = .none
        guard let access else { isPreviewLoading = false; return }
        isPreviewLoading = true
        previewTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let body = try await access.text(id: id)
                guard let self, !Task.isCancelled, self.previewGeneration == requestID, self.previewedID == id else { return }
                self.isPreviewLoading = false
                guard let body else {
                    self.previewedID = nil; self.noticeMessage = noticeKey("The clipboard item is no longer available")
                    return
                }
                self.previewText = body
            } catch {
                guard let self, !Task.isCancelled, self.previewGeneration == requestID else { return }
                self.isPreviewLoading = false; self.noticeMessage = noticeKey("Clipboard storage failed")
            }
        }
    }

    public func closePreview() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        previewedID = nil; previewText = nil; isPreviewLoading = false
    }

    public func pin(_ entry: ClipboardPreview) async {
        guard let access else { return }
        let notify = didMutate
        do { try await access.setPinned(id: entry.id, pinned: !entry.pinned); mutationCompleted(notify: notify) }
        catch { noticeMessage = noticeKey("Clipboard storage failed") }
    }

    public func delete(_ entry: ClipboardPreview) async {
        guard let access else { return }
        let notify = didMutate
        if previewedID == entry.id { closePreview() }
        do { try await access.delete(id: entry.id); mutationCompleted(notify: notify) }
        catch { noticeMessage = noticeKey("Clipboard storage failed") }
    }

    public func clear() async {
        guard let access else { return }
        let notify = didMutate
        closePreview()
        do { try await access.clear(); mutationCompleted(notify: notify) }
        catch { noticeMessage = noticeKey("Clipboard storage failed") }
    }

    private func mutationCompleted(notify: @MainActor () -> Void) {
        // 共享数据的失效通知属于此次操作；窗口 disconnect 不得撤销已发起的通知。
        refresh(); notify()
    }

    public func copy(_ entry: ClipboardPreview, perform: @MainActor (String) -> Void) async {
        await copy(id: entry.id, perform: perform)
    }

    func composition(ids: [String], separator: ClipboardSeparator) async throws -> ClipboardComposition {
        guard let source = access as? any ClipboardCompositionAccess else { throw ClipboardCompositionError.unsupported }
        let request = generation
        let result = try await source.composition(ids: ids, separator: separator)
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        return result
    }

    public func copyPreview(perform: @MainActor (String) -> Void) async {
        guard let id = previewedID else { return }
        await copy(id: id, perform: perform)
    }

    private func copy(id: String, perform: @MainActor (String) -> Void) async {
        guard let access else { return }
        let requestID = generation
        do {
            let body = try await access.text(id: id)
            guard !Task.isCancelled, requestID == generation else { return }
            guard let body else { noticeMessage = noticeKey("The clipboard item is no longer available"); return }
            perform(body)
        } catch {
            guard !Task.isCancelled, requestID == generation else { return }
            noticeMessage = noticeKey("Clipboard storage failed")
        }
    }
}
