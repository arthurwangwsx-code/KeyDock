import Testing
@testable import CommandCore

struct ClipboardCompositionTests {
    @Test func orderAndLiteralSeparatorsArePreserved() throws {
        for separator in ClipboardSeparator.allCases {
            let result = try ClipboardComposition.read(ids: ["b", "a"], separator: separator) { id, _ in id == "a" ? "中文\nA" : "B" }
            #expect(result.ids == ["b", "a"])
            #expect(result.text == "B" + separator.text + "中文\nA")
        }
    }
    @Test func budgetCountsUTF8AndSeparatorBeforeTheNextRead() throws {
        let full = String(repeating: "a", count: ClipboardComposition.maximumBytes)
        let exact = try ClipboardComposition.read(ids: ["a"], separator: .newline) { _, remaining in
            #expect(remaining == full.utf8.count); return full
        }
        #expect(exact.text == full)
        var reads = 0
        #expect(throws: ClipboardCompositionError.tooLarge) {
            try ClipboardComposition.read(ids: ["a", "b"], separator: .newline) { _, _ in reads += 1; return full }
        }
        #expect(reads == 1)
        #expect(throws: ClipboardCompositionError.tooLarge) {
            try ClipboardComposition.read(ids: ["a", "b"], separator: .none) { id, _ in id == "a" ? full : "中" }
        }
    }
    @Test func invalidSelectionNeverReadsBodies() {
        for ids in [[], ["a", "a"], [""], [String(repeating: "a", count: 129)], (0...20).map(String.init)] {
            #expect(throws: ClipboardCompositionError.invalidSelection) {
                try ClipboardComposition.read(ids: ids, separator: .newline) { _, _ in Issue.record("Invalid request read a body"); return "x" }
            }
        }
    }
    @Test func missingMemberNeverProducesPartialText() {
        #expect(throws: ClipboardCompositionError.missingItem) {
            try ClipboardComposition.read(ids: ["a", "missing"], separator: .newline) { id, _ in id == "a" ? "A" : nil }
        }
    }
    @Test func canonicallyEquivalentButDifferentBytesRequireNewReview() throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        #expect(composed == decomposed)
        let old = try ClipboardComposition.read(ids: ["a"], separator: .newline) { _, _ in composed }
        let new = try ClipboardComposition.read(ids: ["a"], separator: .newline) { _, _ in decomposed }
        #expect(old != new)
    }
}
