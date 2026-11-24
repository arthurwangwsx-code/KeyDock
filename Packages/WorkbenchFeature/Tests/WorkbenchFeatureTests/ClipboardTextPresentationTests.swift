import AppKit
import Testing
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct ClipboardTextPresentationTests {
    @Test func canonicallyEquivalentBodyUpdatesTheNativeTextBytes() {
        let view = NSTextView(frame: .zero)
        view.string = "\u{e9}"
        let next = "e\u{301}"
        #expect(view.string == next)
        #expect(!view.string.utf8.elementsEqual(next.utf8))
        ClipboardReadOnlyText.synchronizeText(next, in: view)
        #expect(view.string.utf8.elementsEqual(next.utf8))
    }
    @Test func identicalBodyKeepsTheUsersSelection() {
        let view = NSTextView(frame: .zero)
        view.string = "Synthetic preview text"
        let range = NSRange(location: 2, length: 5)
        view.setSelectedRange(range)
        ClipboardReadOnlyText.synchronizeText("Synthetic preview text", in: view)
        #expect(view.selectedRange() == range)
    }
}
