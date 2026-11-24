import Foundation
import Testing
import CommandCore
@testable import MacAdapters

struct ClipboardCompositionStoreTests {
    @Test func atomicReadPreservesExplicitOrderAndRejectsMissingMember() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Merge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardStore(url: root.appendingPathComponent("clips.sqlite"))
        for text in ["Alpha 中文", "Beta\nline", "Gamma"] { try await store.insert(text: text, source: "Synthetic") }
        let values = try await store.searchPreviews()
        let alpha = try #require(values.first { $0.preview == "Alpha 中文" }), beta = try #require(values.first { $0.preview == "Beta\nline" })
        let value = try await store.composition(ids: [beta.id, alpha.id], separator: .blankLine)
        #expect(value.text == "Beta\nline\n\nAlpha 中文")
        try await store.delete(id: alpha.id)
        await #expect(throws: ClipboardCompositionError.missingItem) { try await store.composition(ids: [beta.id, alpha.id], separator: .newline) }
        #expect(try await store.text(id: beta.id) == "Beta\nline")
    }
    @Test func expiryAndCombinedByteBudgetRejectWholeBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Merge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardStore(url: root.appendingPathComponent("clips.sqlite"))
        let body = String(repeating: "中", count: 200_000)
        try await store.insert(text: body, source: "Synthetic"); try await store.insert(text: body + "B", source: "Synthetic")
        let ids = try await store.searchPreviews().map(\.id)
        await #expect(throws: ClipboardCompositionError.tooLarge) { try await store.composition(ids: ids, separator: .newline) }
        try await store.prune(now: Date().addingTimeInterval(86401))
        await #expect(throws: ClipboardCompositionError.missingItem) { try await store.composition(ids: ids, separator: .newline) }
    }
}
