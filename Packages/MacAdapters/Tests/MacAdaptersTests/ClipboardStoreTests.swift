import Foundation
import Testing
@testable import MacAdapters

@Test func sensitiveTypesAndExclusions() {
    #expect(!ClipboardPolicy.allows(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], source: nil, excluded: []))
    #expect(!ClipboardPolicy.allows(types: ["org.nspasteboard.TransientType"], source: nil, excluded: []))
    #expect(!ClipboardPolicy.allows(types: ["public.text"], source: "password.app", excluded: ["password.app"]))
    #expect(ClipboardPolicy.allows(types: ["public.utf8-plain-text"], source: "editor", excluded: []))
}

@Test func clipboardRetentionPinningCapacityAndClear() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var limits = ClipboardLimits(); limits.retention = 60; limits.maxEntries = 2
    let store = try ClipboardStore(url: directory.appendingPathComponent("clipboard.sqlite"), limits: limits)
    try await store.insert(text: "pinned", source: "synthetic")
    let pinned = try #require(await store.entries().first)
    try await store.setPinned(id: pinned.id, pinned: true)
    try await store.insert(text: "older", source: "synthetic")
    try await store.insert(text: "latest", source: "synthetic")
    #expect(try await store.entries().map(\.text).contains("pinned"))
    #expect(try await store.entries().count == 2)
    try await store.prune(now: Date().addingTimeInterval(120))
    #expect(try await store.entries().map(\.text) == ["pinned"])
    try await store.clear()
    #expect(try await store.entries().isEmpty)
}

@Test func clipboardPreservesEmbeddedNullWithoutDuplicateConfusion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ClipboardStore(url: directory.appendingPathComponent("clipboard.sqlite"))
    try await store.insert(text: "A\0B", source: "synthetic")
    try await store.insert(text: "A", source: "synthetic")
    let values = try await store.entries().map(\.text)
    #expect(Set(values) == ["A\0B", "A"])
}
