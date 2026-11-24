import Foundation
import Testing
import MacAdapters
@testable import WorkbenchFeature

private actor PaletteClipboardAccess: ClipboardAccess {
    let entries: [ClipboardPreview] = ["alpha", "beta", "gamma"].map {
        ClipboardPreview(id: $0, preview: $0, createdAt: Date(), pinned: false, source: "Synthetic", byteCount: 12)
    }
    var blockText = false
    var deleted: Set<String> = []
    var pending: [(String, CheckedContinuation<String?, Never>)] = []
    func searchPreviews(query: String) async throws -> [ClipboardPreview] { entries.filter { !deleted.contains($0.id) && (query.isEmpty || $0.preview.contains(query)) } }
    func text(id: String) async throws -> String? {
        if blockText { return await withCheckedContinuation { pending.append((id, $0)) } }
        return deleted.contains(id) ? nil : "Full \(id) body"
    }
    func setPinned(id: String, pinned: Bool) async throws {}
    func delete(id: String) async throws { deleted.insert(id) }
    func clear() async throws { deleted = Set(entries.map(\.id)) }
    func setBlocked() { blockText = true }
    func waitForPending(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while pending.count < count {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func resolveAll() {
        let work = pending; pending = []; blockText = false
        for (id, continuation) in work { continuation.resume(returning: deleted.contains(id) ? nil : "Full \(id) body") }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ClipboardPanelSessionTests {
    @Test func independentPaletteSelectsSearchResultsAndCopiesFullCurrentBody() async throws {
        let access = PaletteClipboardAccess(), session = ClipboardPanelSession()
        defer { session.dismiss() }
        var copied: [String] = [], inserted: [String] = []
        session.onCopy = { copied.append($0) }; session.onInsert = { text, _ in inserted.append(text) }
        session.present(access: access, onMutation: {})
        await session.browser.searchTask?.value
        #expect(session.selectedID == "alpha")
        session.move(1); #expect(session.selectedID == "beta")
        session.move(99); #expect(session.selectedID == "gamma")
        session.move(-99); #expect(session.selectedID == "alpha")
        session.editQuery("beta"); await session.browser.searchTask?.value
        #expect(session.selection?.id == "beta")
        session.commit(insert: false); await session.commitTask?.value
        #expect(copied == ["Full beta body"] && inserted.isEmpty)
        session.commit(insert: true); await session.commitTask?.value
        #expect(inserted.isEmpty && !session.noticeMessage.rendered().isEmpty)
        session.canInsert = true; session.commit(insert: true); await session.commitTask?.value
        #expect(inserted == ["Full beta body"])
    }
    @Test func changedSelectionDismissOrQueryRejectsLateCommittedText() async throws {
        for mode in 0..<3 {
            let access = PaletteClipboardAccess(), session = ClipboardPanelSession()
            var copied = 0
            session.onCopy = { _ in copied += 1 }
            session.present(access: access, onMutation: {})
            await session.browser.searchTask?.value; await session.browser.previewTask?.value
            await access.setBlocked()
            session.commit(insert: false)
            let oldTask = session.commitTask
            try await access.waitForPending(1)
            if mode == 0 { session.move(1) }
            else if mode == 1 { session.dismiss() }
            else { session.editQuery("beta") }
            await access.resolveAll(); await oldTask?.value
            #expect(copied == 0)
            session.dismiss()
        }
    }
    @Test func repeatedSubmitHasOneReadAndDeletedEntryCannotBeCopied() async throws {
        let access = PaletteClipboardAccess(), session = ClipboardPanelSession()
        defer { session.dismiss() }
        var copies = 0; session.onCopy = { _ in copies += 1 }
        session.present(access: access, onMutation: {})
        await session.browser.searchTask?.value; await session.browser.previewTask?.value
        await access.setBlocked()
        session.commit(insert: false); let task = session.commitTask
        session.commit(insert: false)
        try await access.waitForPending(1)
        try await access.delete(id: "alpha"); await access.resolveAll(); await task?.value
        #expect(copies == 0 && !session.browser.notice.isEmpty)
    }
    @Test func reopeningDropsOldQueryAndUsesAnIndependentPresentation() async throws {
        let access = PaletteClipboardAccess(), session = ClipboardPanelSession()
        session.present(access: access, onMutation: {})
        session.editQuery("gamma"); await session.browser.searchTask?.value
        let previousFocus = session.focusRequest
        session.dismiss(); session.present(access: access, onMutation: {})
        await session.browser.searchTask?.value
        #expect(session.browser.query.isEmpty && session.selectedID == "alpha" && previousFocus != session.focusRequest)
        session.dismiss()
    }
    @Test func handedOffCommitTokenExpiresOnQuerySelectionOrPresentationChanges() async throws {
        for mode in 0..<3 {
            let access = PaletteClipboardAccess(), session = ClipboardPanelSession()
            var token: UUID?
            session.onInsert = { _, value in token = value }
            session.present(access: access, onMutation: {})
            await session.browser.searchTask?.value; await session.browser.previewTask?.value
            session.canInsert = true; session.commit(insert: true); await session.commitTask?.value
            let value = try #require(token)
            #expect(session.acceptsCommit(value))
            if mode == 0 { session.editQuery("beta") }
            else if mode == 1 { session.move(1) }
            else { session.dismiss() }
            #expect(!session.acceptsCommit(value))
            session.dismiss()
        }
    }
    @Test func copyOnlyPresentationKeepsReturnAppWithoutAnInsertionTarget() async {
        let session = ClipboardPanelSession(), access = PaletteClipboardAccess()
        let origin = TargetIdentity(pid: 1234, launchDate: Date(timeIntervalSince1970: 100), name: "Synthetic editor")
        session.present(access: access, returnTarget: origin, onMutation: {})
        await session.browser.searchTask?.value
        #expect(!session.canInsert && session.returnTarget == origin)
        session.editQuery("beta"); await session.browser.searchTask?.value
        #expect(session.returnTarget == origin)
        session.dismiss()
        #expect(session.returnTarget == nil)
    }
}
