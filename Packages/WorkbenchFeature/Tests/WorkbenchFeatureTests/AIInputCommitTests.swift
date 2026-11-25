import Foundation
import AppKit
import AutomationCore
import AgentCore
import KeyDockUI
import Testing
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct AIInputCommitTests {
    @Test func canonicallyEquivalentManualEditKeepsExactBytesAndInvalidatesOldReply() {
        let original = "Caf\u{e9}", edited = "Cafe\u{301}"
        #expect(original == edited && !original.utf8.elementsEqual(edited.utf8))
        let draft = AIDraftDocument(input: original, actionID: UUID(), target: nil, source: .selection)
        let revision = draft.revision, run = UUID(); draft.latestRunID = run
        draft.editInput(edited)
        #expect(draft.input.utf8.elementsEqual(edited.utf8))
        #expect(draft.revision != revision && draft.source == .manual && draft.latestRunID == run)
    }
    @Test func canonicallyEquivalentClipboardRefreshInvalidatesSameSourceRevision() {
        let original = "Caf\u{e9}", edited = "Cafe\u{301}"
        let draft = AIDraftDocument(input: original, actionID: UUID(), target: nil, source: .clipboard)
        let revision = draft.revision
        draft.useClipboard(edited)
        #expect(draft.input.utf8.elementsEqual(edited.utf8) && draft.revision != revision && draft.source == .clipboard)
        let confirmed = draft.revision
        draft.useClipboard(edited)
        #expect(draft.revision == confirmed)
    }
    @Test func markedTextBlocksUIRequestsWithoutBlockingPreparedWorkflowExecution() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store, editor = NSTextView(frame: .zero)
            editor.setMarkedText("fanyi", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            store.inputCommitAllowed = { KDTextInputState.permitsAction(in: editor) }
            let draft = store.createDraft(actionID: fixture.action.id, input: "Synthetic committed input")
            let workflow = WorkflowDefinition(name: "Synthetic trim", steps: [.init(operation: .transform(.trim))])
            #expect(!store.canCommitCurrentInput && store.canRunAIFromInput(draft))
            #expect(store.runAIFromInput(draft) == nil)
            let flow = store.performUserInputAction { store.runWorkflow(workflow, input: " Synthetic input ") }
            let agent = store.performUserInputAction { store.runAgent(AgentDefinition(), input: "Synthetic input") }
            #expect(!flow && !agent && store.tasks.isEmpty && store.executionReservations.isEmpty)
            #expect(try await fixture.server.stats()["post_requests"] == 0)
            // 非UI的已准备工作流不受无关编辑器组合态影响。
            let prepared = try #require(store.runWorkflow(workflow, input: " Synthetic prepared ", interaction: false))
            try await fixture.drain(prepared)
            #expect(store.tasks.first { $0.id == prepared }?.output == "Synthetic prepared")
            editor.unmarkText()
            #expect(store.canCommitCurrentInput)
            let ai = try #require(store.runAIFromInput(draft))
            try await fixture.drain(ai)
            #expect(store.tasks.first { $0.id == ai }?.status == .completed)
            #expect(try await fixture.server.stats()["post_requests"] == 1)
            try fixture.assertNoCommandEffects()
        }
    }
    @Test func inputGateAcceptsOrdinaryRespondersAndRequiresCompositionToEnd() {
        #expect(KDTextInputState.permitsAction(in: nil))
        #expect(KDTextInputState.permitsAction(in: NSResponder()))
        let editor = NSTextView(frame: .zero)
        editor.string = "Synthetic text"
        #expect(KDTextInputState.permitsAction(in: editor))
        editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(!KDTextInputState.permitsAction(in: editor))
        editor.unmarkText(); #expect(KDTextInputState.permitsAction(in: editor))
    }

    @Test func equivalentByteEditCannotReceiveHeldCommandProposal() async throws {
        try await withStoreHTTPFixture(path: "proposal-held") { fixture in
            let original = fixture.directory.path + "/Caf\u{e9}", edited = fixture.directory.path + "/Cafe\u{301}"
            let draft = fixture.store.createDraft(input: original)
            var reviews = 0
            fixture.store.onReviewCommand = { _ in reviews += 1 }
            fixture.store.generateCommandProposal(draft: draft)
            let id = try #require(fixture.store.proposalRequests[draft.id])
            try await storeEventually { try await fixture.server.stats()["proposal_started"] == 1 }
            draft.editInput(edited); draft.notice = "Synthetic current draft notice"
            try await fixture.server.releaseProposals(); try await fixture.drain(id)
            #expect(reviews == 0 && fixture.store.pendingCommandReviews.isEmpty)
            #expect(draft.input.utf8.elementsEqual(edited.utf8) && draft.notice == "Synthetic current draft notice")
            #expect(fixture.store.tasks.first { $0.id == id }?.status == .draftReady)
            try fixture.assertNoCommandEffects(marker: URL(fileURLWithPath: original))
        }
    }
}
