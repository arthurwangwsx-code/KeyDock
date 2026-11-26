import AppKit
import Testing
import KeyDockUI

@Suite @MainActor struct RestrictedSearchEditorTests {
    @Test func nativePasteEntryPointsPreserveQueryAndSelection() {
        let editor = KDRestrictedFieldEditor(frame: .zero)
        editor.string = "synthetic typed query"; editor.setSelectedRange(NSRange(location: 10, length: 5))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("External synthetic text", forType: .string)
        let count = board.changeCount
        editor.paste(nil); editor.pasteAsPlainText(nil); editor.pasteAsRichText(nil)
        #expect(!editor.readSelection(from: board)); #expect(!editor.readSelection(from: board, type: .string))
        #expect(editor.string == "synthetic typed query")
        #expect(editor.selectedRange() == NSRange(location: 10, length: 5)); #expect(board.changeCount == count)
    }
    @Test func typingAndMarkedInputAreStillNative() {
        let editor = KDRestrictedFieldEditor(frame: .zero)
        editor.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
        editor.setMarkedText("组合", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 6, length: 0))
        #expect(editor.hasMarkedText()); #expect(editor.string == "typed 组合")
        editor.unmarkText(); #expect(!editor.hasMarkedText())
    }
}
