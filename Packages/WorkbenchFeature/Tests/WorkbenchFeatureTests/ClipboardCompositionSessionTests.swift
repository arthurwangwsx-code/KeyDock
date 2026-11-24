import Foundation
import Testing
import CommandCore
import MacAdapters
@testable import WorkbenchFeature

private actor CompositionSource: ClipboardCompositionAccess {
    let entries = (0..<21).map { ClipboardPreview(id: String($0), preview: "Synthetic \($0)", createdAt: Date(), pinned: false, source: "Synthetic", byteCount: 12) }
    var suffix = "", deleted: Set<String> = [], block = false
    var pending: [CheckedContinuation<Void, Never>] = []
    func searchPreviews(query: String) async throws -> [ClipboardPreview] { entries.filter { query.isEmpty || $0.preview.contains(query) } }
    func text(id: String) async throws -> String? { "Full " + id }
    func setPinned(id: String, pinned: Bool) async throws {}
    func delete(id: String) async throws { deleted.insert(id) }
    func clear() async throws { deleted = Set(entries.map(\.id)) }
    func composition(ids: [String], separator: ClipboardSeparator) async throws -> ClipboardComposition {
        let value = try ClipboardComposition.read(ids: ids, separator: separator) { id, _ in deleted.contains(id) ? nil : "Full " + id + suffix }
        if block { await withCheckedContinuation { pending.append($0) } }
        return value
    }
    func setSuffix(_ value: String) { suffix = value }
    func setBlocked() { block = true }
    func waitForPending() async throws {
        let end = ContinuousClock.now + .seconds(3)
        while pending.isEmpty { guard ContinuousClock.now < end else { throw CocoaError(.coderInvalidValue) }; try await Task.sleep(for: .milliseconds(5)) }
    }
    func resolve() { let work = pending; pending = []; block = false; for item in work { item.resume() } }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ClipboardCompositionSessionTests {
    private func session() throws -> (ClipboardPanelSession, UserDefaults, String) {
        let domain = "KeyDock-Synthetic-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: domain))
        return (ClipboardPanelSession(preferences: ClipboardPanelPreferences(defaults: defaults)), defaults, domain)
    }
    @Test func selectionSurvivesSearchAndCopiesOneOrderedMergedBody() async throws {
        let (session, defaults, domain) = try session(); defer { session.dismiss(); defaults.removePersistentDomain(forName: domain) }
        let source = CompositionSource(); var copies: [String] = []
        session.onCopy = { copies.append($0) }; session.present(access: source, onMutation: {})
        await session.browser.searchTask?.value
        let values = session.browser.results
        session.toggleMark(values[1]); await session.compositionTask?.value
        session.toggleMark(values[0]); await session.compositionTask?.value
        session.editQuery("no matches"); await session.browser.searchTask?.value; await session.compositionTask?.value
        #expect(session.selection == nil && session.canCommit)
        #expect(session.previewText == "Full 1\nFull 0")
        session.moveMark(id: "0", delta: -1); await session.compositionTask?.value
        session.commit(insert: false); await session.commitTask?.value
        #expect(copies == ["Full 0\nFull 1"])
        session.dismiss(); #expect(session.markedItems.isEmpty && session.composition == nil)
    }
    @Test func changedOrDeletedBodyCannotBypassPreviewReview() async throws {
        let (session, defaults, domain) = try session(); defer { session.dismiss(); defaults.removePersistentDomain(forName: domain) }
        let source = CompositionSource(); var copies = 0
        session.onCopy = { _ in copies += 1 }; session.present(access: source, onMutation: {})
        await session.browser.searchTask?.value
        session.toggleMark(session.browser.results[0]); await session.compositionTask?.value
        await source.setSuffix(" changed")
        session.commit(insert: false); await session.commitTask?.value
        #expect(copies == 0 && session.previewText == "Full 0 changed" && !session.noticeMessage.rendered().isEmpty)
        session.commit(insert: false); await session.commitTask?.value; #expect(copies == 1)
        try await source.delete(id: "0")
        session.commit(insert: false); await session.commitTask?.value
        #expect(copies == 1 && !session.canCommit && session.markedItems.count == 1)
    }
    @Test func preferenceChangeRevokesPendingCommit() async throws {
        let (session, defaults, domain) = try session(); defer { session.dismiss(); defaults.removePersistentDomain(forName: domain) }
        let source = CompositionSource(); var inserts: [String] = []
        session.onInsert = { text, _ in inserts.append(text) }; session.present(access: source, onMutation: {})
        session.canInsert = true; await session.browser.searchTask?.value
        session.toggleMark(session.browser.results[0]); await session.compositionTask?.value
        await source.setBlocked()
        session.commit(insert: true); let old = session.commitTask
        session.commit(insert: true); try await source.waitForPending()
        session.preferences.primaryAction = .copy
        await source.resolve(); await old?.value; await session.compositionTask?.value
        #expect(inserts.isEmpty)
        session.commitAlternate(); await session.commitTask?.value
        #expect(inserts == ["Full 0"])
        let restored = ClipboardPanelPreferences(defaults: defaults)
        #expect(restored.primaryAction == .copy)
    }
    @Test func repeatedMergedSubmitDispatchesExactlyOneInsertion() async throws {
        let (session, defaults, domain) = try session(); defer { session.dismiss(); defaults.removePersistentDomain(forName: domain) }
        let source = CompositionSource(); var inserts: [String] = []
        session.onInsert = { text, _ in inserts.append(text) }; session.present(access: source, onMutation: {})
        session.canInsert = true; await session.browser.searchTask?.value
        session.toggleMark(session.browser.results[0]); await session.compositionTask?.value
        session.toggleMark(session.browser.results[1]); await session.compositionTask?.value
        await source.setBlocked()
        session.commit(insert: true); let pending = session.commitTask
        session.commit(insert: true); try await source.waitForPending()
        await source.resolve(); await pending?.value
        #expect(inserts == ["Full 0\nFull 1"])
    }
    @Test func itemLimitAndCopyFailureKeepTheSelection() async throws {
        let (session, defaults, domain) = try session(); defer { session.dismiss(); defaults.removePersistentDomain(forName: domain) }
        let source = CompositionSource()
        session.present(access: source, onMutation: {}); await session.browser.searchTask?.value
        for item in session.browser.results { session.toggleMark(item) }
        await session.compositionTask?.value
        #expect(session.markedItems.count == 20)
        session.onCopy = { _ in throw CocoaError(.fileWriteUnknown) }
        session.commit(insert: false); await session.commitTask?.value
        #expect(session.markedItems.count == 20 && session.canCommit && !session.noticeMessage.rendered().isEmpty)
    }
}
