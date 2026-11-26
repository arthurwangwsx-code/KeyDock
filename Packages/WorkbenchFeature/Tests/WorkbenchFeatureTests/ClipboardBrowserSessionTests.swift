import Foundation
import Testing
import MacAdapters
@testable import WorkbenchFeature

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ClipboardBrowserSessionTests {
    @Test func sqliteMatchesBeyondPreviewAndReturnsOnlyBoundedSummaries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ClipboardStore(url: directory.appendingPathComponent("clipboard.sqlite"))
        let body = String(repeating: "x", count: 8_000) + " CAFÉ 中文 needle\0tail"
        try await database.insert(text: body, source: "synthetic")
        let values = try await database.searchPreviews(query: "café 中文 needle\0tail")
        let item = try #require(values.first)
        #expect(values.count == 1 && item.preview.count == 400)
        #expect(!item.preview.contains("needle"))
        #expect(item.byteCount == body.utf8.count)
        #expect(try await database.text(id: item.id) == body)
    }

    @Test func fiveHundredRowsNearCapacityDoNotReturnFullBodiesToWindow() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ClipboardStore(url: directory.appendingPathComponent("clipboard.sqlite"))
        let prefix = String(repeating: "x", count: 65_500)
        for index in 0..<500 { try await database.insert(text: prefix + " synthetic-\(index)", source: "synthetic") }
        let values = try await database.searchPreviews(query: "synthetic-")
        #expect(values.count == 500)
        #expect(values.allSatisfy { $0.preview.count <= 400 })
        #expect(values.reduce(0) { $0 + $1.byteCount } > 32_000_000)
        #expect(values.reduce(0) { $0 + $1.preview.utf8.count } <= 200_000)
    }

    @Test func independentWindowsKeepQueriesAcrossPinDeleteClearAndCopyFullText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try ClipboardStore(url: directory.appendingPathComponent("clipboard.sqlite"))
        let firstBody = String(repeating: "x", count: 600) + " alpha needle"
        try await database.insert(text: firstBody, source: "synthetic")
        try await database.insert(text: "beta other", source: "synthetic")
        let first = ClipboardBrowserSession(), second = ClipboardBrowserSession()
        defer { first.disconnect(); second.disconnect() }
        let broadcast: @MainActor () -> Void = { [weak first, weak second] in first?.refresh(); second?.refresh() }
        first.connect(to: database, onMutation: broadcast); second.connect(to: database, onMutation: broadcast)
        first.query = "needle"; second.query = "other"
        await first.searchTask?.value; await second.searchTask?.value
        let item = try #require(first.results.first)
        #expect(first.results.count == 1 && second.results.count == 1)
        first.preview(item); await first.previewTask?.value
        #expect(first.previewText == firstBody)
        var copied: String?
        await first.copy(item, perform: { copied = $0 })
        #expect(copied == firstBody)
        await first.pin(item)
        await first.searchTask?.value; await second.searchTask?.value
        #expect(first.query == "needle" && second.query == "other")
        #expect(first.results.first?.pinned == true)
        await first.delete(try #require(first.results.first))
        await first.searchTask?.value; await second.searchTask?.value
        #expect(first.results.isEmpty && first.previewedID == nil && first.previewText == nil)
        #expect(second.results.count == 1 && second.query == "other")
        await second.clear()
        await first.searchTask?.value; await second.searchTask?.value
        #expect(first.query == "needle" && second.query == "other")
        #expect(first.results.isEmpty && second.results.isEmpty)
    }

    @Test func lateSearchSuccessAndFailureCannotReplaceNewerResults() async throws {
        let source = DeferredClipboardSource(), session = ClipboardBrowserSession(access: source)
        defer { session.disconnect() }
        session.query = "old"
        let oldTask = try #require(session.searchTask)
        let old = try await source.waitForSearch("old")
        session.query = "new"
        let newTask = try #require(session.searchTask)
        let new = try await source.waitForSearch("new")
        let expected = preview("new")
        await source.completeSearch(new, with: [expected]); await newTask.value
        await source.failSearch(old); await oldTask.value
        #expect(session.query == "new" && session.results == [expected] && session.notice.isEmpty)
        session.query = "first"
        let firstTask = try #require(session.searchTask)
        let first = try await source.waitForSearch("first")
        session.query = "last"
        let lastTask = try #require(session.searchTask)
        let last = try await source.waitForSearch("last")
        await source.completeSearch(last, with: [preview("last")]); await lastTask.value
        await source.completeSearch(first, with: [preview("stale")]); await firstTask.value
        #expect(session.results.map(\.id) == ["last"] && session.notice.isEmpty)
    }

    @Test func latePreviewCannotResurrectAnotherSelectionOrDeletedItem() async throws {
        let source = DeferredClipboardSource(), session = ClipboardBrowserSession(access: source)
        defer { session.disconnect() }
        session.preview(preview("first"))
        let oldTask = try #require(session.previewTask)
        let old = try await source.waitForText("first")
        session.preview(preview("second"))
        let newTask = try #require(session.previewTask)
        let new = try await source.waitForText("second")
        await source.completeText(new, with: "full second body"); await newTask.value
        await source.completeText(old, with: "stale first body"); await oldTask.value
        #expect(session.previewedID == "second" && session.previewText == "full second body")
        session.preview(preview("deleted"))
        let deletedTask = try #require(session.previewTask)
        let deleted = try await source.waitForText("deleted")
        await session.delete(preview("deleted"))
        let queryTask = try #require(session.searchTask)
        let query = try await source.waitForSearch("")
        await source.completeSearch(query, with: []); await queryTask.value
        await source.completeText(deleted, with: "late deleted body"); await deletedTask.value
        #expect(session.previewedID == nil && session.previewText == nil)
    }

    @Test func queryFailureIsVisibleOnlyInItsOwnWorkspaceSession() async throws {
        let source = DeferredClipboardSource()
        let first = ClipboardBrowserSession(access: source), second = ClipboardBrowserSession(access: source)
        defer { first.disconnect(); second.disconnect() }
        first.query = "failure"; second.query = "success"
        let firstTask = try #require(first.searchTask), secondTask = try #require(second.searchTask)
        let failure = try await source.waitForSearch("failure"), success = try await source.waitForSearch("success")
        await source.failSearch(failure); await firstTask.value
        await source.completeSearch(success, with: [preview("success")]); await secondTask.value
        #expect(!first.notice.isEmpty && first.results.isEmpty && !first.isSearching)
        #expect(first.queryOutcome == .failed && first.queryOutcome?.isEmpty == false)
        #expect(second.notice.isEmpty && second.results.map(\.id) == ["success"])
        #expect(second.queryOutcome == .items)
        first.refresh()
        let retryTask = try #require(first.searchTask)
        #expect(first.isSearching && first.queryOutcome == nil)
        let retry = try await source.waitForSearch("failure")
        await source.completeSearch(retry, with: []); await retryTask.value
        #expect(first.queryOutcome == .noMatches && first.notice.isEmpty)
        first.query = ""
        let emptyTask = try #require(first.searchTask)
        let empty = try await source.waitForSearch("")
        await source.failSearch(empty); await emptyTask.value
        #expect(first.queryOutcome == .failed && first.queryOutcome?.isEmpty == false)
        first.refresh()
        let finalTask = try #require(first.searchTask)
        let recovered = try await source.waitForSearch("")
        await source.completeSearch(recovered, with: []); await finalTask.value
        #expect(first.queryOutcome == .emptyHistory)
        first.disconnect()
        #expect(first.queryOutcome == nil && !first.isSearching)
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ClipboardQuery-" + UUID().uuidString) }
    private func preview(_ id: String) -> ClipboardPreview { ClipboardPreview(id: id, preview: id, createdAt: Date(), pinned: false, source: "synthetic", byteCount: id.utf8.count) }
}

/// 故意忽略 Task 取消，精确控制晚到的成功/失败，验证 generation 而非只验证取消标志。
private actor DeferredClipboardSource: ClipboardAccess {
    private struct Search { let id: UUID; let query: String; let continuation: CheckedContinuation<[ClipboardPreview], any Error> }
    private struct Text { let id: UUID; let itemID: String; let continuation: CheckedContinuation<String?, any Error> }
    private var searches: [Search] = []
    private var texts: [Text] = []
    enum FixtureError: Error { case synthetic, deadline }
    func searchPreviews(query: String) async throws -> [ClipboardPreview] {
        try await withCheckedThrowingContinuation { searches.append(Search(id: UUID(), query: query, continuation: $0)) }
    }
    func text(id: String) async throws -> String? {
        try await withCheckedThrowingContinuation { texts.append(Text(id: UUID(), itemID: id, continuation: $0)) }
    }
    func setPinned(id: String, pinned: Bool) async throws {}
    func delete(id: String) async throws {}
    func clear() async throws {}
    func waitForSearch(_ query: String) async throws -> UUID {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let request = searches.first(where: { $0.query == query }) { return request.id }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureError.deadline
    }
    func waitForText(_ id: String) async throws -> UUID {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let request = texts.first(where: { $0.itemID == id }) { return request.id }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureError.deadline
    }
    func completeSearch(_ id: UUID, with results: [ClipboardPreview]) {
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return }
        searches.remove(at: index).continuation.resume(returning: results)
    }
    func failSearch(_ id: UUID) {
        guard let index = searches.firstIndex(where: { $0.id == id }) else { return }
        searches.remove(at: index).continuation.resume(throwing: FixtureError.synthetic)
    }
    func completeText(_ id: UUID, with body: String?) {
        guard let index = texts.firstIndex(where: { $0.id == id }) else { return }
        texts.remove(at: index).continuation.resume(returning: body)
    }
}
