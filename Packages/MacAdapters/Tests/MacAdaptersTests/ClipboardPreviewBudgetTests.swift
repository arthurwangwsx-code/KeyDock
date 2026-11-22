import Foundation
import Testing
import MacAdapters

@Test func clipboardPreviewStaysByteBoundedEvenForOneVeryLongGrapheme() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-PreviewBudget-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ClipboardStore(url: directory.appendingPathComponent("clips.sqlite"))
    let text = "a" + String(repeating: "\u{0301}", count: 8000) + "synthetic-tail-keyword"
    try await store.insert(text: text, source: "synthetic-budget")
    let results = try await store.searchPreviews(query: "synthetic-tail-keyword")
    let row = try #require(results.first)
    #expect(results.count == 1 && row.preview.utf8.count <= 1600)
    #expect(!row.preview.contains("synthetic-tail-keyword"))
    #expect(row.byteCount == text.utf8.count)
    #expect(try await store.text(id: row.id) == text)
}
