import Foundation
import Testing
import MacAdapters
@testable import WorkbenchFeature

enum ClipboardDisconnectMutation: String, CaseIterable, Sendable { case pin, delete, clear }

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ClipboardMutationDisconnectTests {
    @Test(arguments: ClipboardDisconnectMutation.allCases)
    func successfulMutationStillInvalidatesOtherWindowAfterInitiatorDisconnects(_ operation: ClipboardDisconnectMutation) async throws {
        let item = ClipboardPreview(id: "synthetic", preview: "needle synthetic", createdAt: Date(), pinned: false, source: "fixture", byteCount: 16)
        let source = GatedClipboardMutationSource(item: item)
        let first = ClipboardBrowserSession(), second = ClipboardBrowserSession()
        defer { first.disconnect(); second.disconnect() }
        var notifications = 0
        first.connect(to: source, onMutation: { [weak second] in notifications += 1; second?.refresh() })
        second.connect(to: source)
        first.query = "needle"; second.query = "needle"
        await first.searchTask?.value; await second.searchTask?.value
        #expect(second.results.map(\.id) == [item.id])
        let mutation = Task { @MainActor in
            switch operation {
            case .pin: await first.pin(item)
            case .delete: await first.delete(item)
            case .clear: await first.clear()
            }
        }
        // Gate 保证数据库调用已开始且尚未成功，再模拟关闭 A 窗口。
        try await source.waitUntilMutationIsSuspended()
        first.disconnect()
        #expect(first.results.isEmpty && !first.isSearching)
        await source.releaseMutation()
        await mutation.value
        await second.searchTask?.value
        #expect(notifications == 1)
        #expect(second.query == "needle")
        switch operation {
        case .pin: #expect(second.results.first?.pinned == true)
        case .delete, .clear: #expect(second.results.isEmpty)
        }
        #expect(first.results.isEmpty && !first.isSearching)
    }
}

/// 不访问系统剪贴板或文件：暂停实际变更，确定地制造 await/disconnect 竞争。
private actor GatedClipboardMutationSource: ClipboardAccess {
    private var item: ClipboardPreview?
    private var isSuspended = false
    private var gate: CheckedContinuation<Void, Never>?
    init(item: ClipboardPreview) { self.item = item }
    func searchPreviews(query: String) async throws -> [ClipboardPreview] {
        guard let item, query.isEmpty || item.preview.localizedCaseInsensitiveContains(query) else { return [] }
        return [item]
    }
    func text(id: String) async throws -> String? { item?.id == id ? item?.preview : nil }
    func setPinned(id: String, pinned: Bool) async throws {
        await suspendMutation()
        if let item, item.id == id {
            self.item = ClipboardPreview(id: item.id, preview: item.preview, createdAt: item.createdAt, pinned: pinned, source: item.source, byteCount: item.byteCount)
        }
    }
    func delete(id: String) async throws {
        await suspendMutation()
        if item?.id == id { item = nil }
    }
    func clear() async throws { await suspendMutation(); item = nil }
    private func suspendMutation() async {
        await withCheckedContinuation { continuation in gate = continuation; isSuspended = true }
    }
    func waitUntilMutationIsSuspended() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if isSuspended { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        struct GateDeadline: Error {}
        throw GateDeadline()
    }
    func releaseMutation() {
        let continuation = gate; gate = nil; isSuspended = false
        continuation?.resume()
    }
}
