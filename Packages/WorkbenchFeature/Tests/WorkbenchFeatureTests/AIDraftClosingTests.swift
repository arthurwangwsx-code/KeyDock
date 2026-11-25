import Foundation
import Testing
@testable import WorkbenchFeature

@MainActor private final class DraftDrainGate {
    var continuation: CheckedContinuation<Void,Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite(.serialized) @MainActor struct AIDraftClosingTests {
    @Test func aChangedOriginalCannotBeDiscardedFromAnOldCloseReview() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, draft = store.createDraft(input:"Synthetic original")
        let intent = AIDraftCloseIntent(document:draft)
        draft.editInput("Synthetic newer input")
        #expect(await intent.perform(in:store) == false && store.ownsDraft(draft) && !draft.isClosing && draft.input == "Synthetic newer input")
        #expect(intent.preview == "Synthetic original")
        #expect(await AIDraftCloseIntent(document:draft).perform(in:store))
        await fixture.cleanup()
    }
    @Test func closeWaitsForTheActualWorkerEvenWhenItsCallerIsCancelled() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, draft = store.createDraft(input:"Synthetic closing input"), gate = DraftDrainGate(), id = UUID()
        #expect(store.reserveExecution(id,draft:draft))
        store.tasks.insert(.init(id:id,title:"Synthetic real worker",state:.running,draftID:draft.id),at:0)
        store.aiTaskIDs.insert(id)
        store.taskHandles[id] = Task { await gate.wait(); store.updateTask(id,state:.cancelled,finished:true); store.finishExecutionReservation(id) }
        try await storeEventually { gate.continuation != nil }
        let closing = Task { await store.closeDraftAndWait(draft) }
        try await storeEventually { draft.isClosing }
        closing.cancel()
        #expect(store.ownsDraft(draft) && !draft.isDiscarded && store.taskHandles[id] != nil && store.executionReservations.contains(id))
        let revision = draft.revision
        draft.editInput("Must not replace closing input"); draft.useClipboard("Must not replace closing input"); draft.clearInput(); draft.selectAction(UUID())
        #expect(draft.input == "Synthetic closing input" && draft.revision == revision && store.validatedAIInput(draft) == nil)
        #expect(await store.closeDraftAndWait(draft) == false)
        let newer = store.createDraft(input:"Synthetic independent draft")
        gate.release()
        #expect(await closing.value)
        #expect(draft.isDiscarded && !draft.isClosing && draft.input.isEmpty && !store.ownsDraft(draft) && store.taskHandles[id] == nil && !store.executionReservations.contains(id))
        #expect(store.tasks.first(where:{$0.id == id})?.status == .cancelled && store.ownsDraft(newer))
        await fixture.cleanup()
    }

    @Test func activeNetworkRequestIsCancelledWithoutDeletingItsHistoryOrCopying() async throws {
        var copied: [String] = []
        try await withStoreHTTPFixture(path:"slow",clipboardWriter:{ copied.append($0) }) { fixture in
            var action = fixture.action; action.output = .copy
            let store = fixture.store, draft = store.createDraft(input:"Synthetic slow AI input")
            let id = try #require(store.runAI(action:action,draft:draft))
            try await storeEventually { try await fixture.server.stats()["slow_open"] == 1 }
            #expect(await store.closeDraftAndWait(draft))
            #expect(draft.isDiscarded && draft.input.isEmpty && store.taskHandles[id] == nil && !store.executionReservations.contains(id))
            #expect(store.tasks.first(where:{$0.id == id})?.status == .cancelled && store.latestAutoCopyRunID == nil)
            #expect(await store.aiInvocationStore.list().first(where:{$0.id == id})?.state == .cancelled)
            #expect(copied.isEmpty)
        }
    }

    @Test func closingHeldProposalCannotCreateAReviewAfterTheDraftHasGone() async throws {
        try await withStoreHTTPFixture(path:"proposal-held") { fixture in
            let store = fixture.store, session = WorkspaceSession()
            let token = try #require(store.beginTextContextImport(session))
            #expect(store.commitTextContext("Synthetic input",kind:.textFile,name:"Synthetic.txt",session:session,token:token))
            let draft = try #require(store.createToolsDraft(actionID:fixture.action.id,session:session))
            store.generateCommandProposal(draft:draft)
            let id = try #require(store.tasks.first?.id)
            try await storeEventually { try await fixture.server.stats()["proposal_started"] == 1 }
            #expect(await store.closeDraftAndWait(draft))
            try await fixture.server.releaseProposals()
            #expect(draft.isDiscarded && draft.inputProvenance == nil && store.pendingCommandReviews.isEmpty && store.proposalRequests[draft.id] == nil)
            #expect(store.tasks.first(where:{$0.id == id})?.inputProvenance?.displayName == "Synthetic.txt")
            #expect(session.toolsText == "Synthetic input")
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func closingOneSharedDocumentReleasesItsWindowsAndKeepsOtherDrafts() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, draft = store.createDraft(input:"Synthetic shared draft"), other = store.createDraft(input:"Synthetic other draft")
        let launcher = LauncherSession(store:store), workspace = WorkspaceSession()
        let intent = AIDraftCloseIntent(document:draft)
        launcher.draft = draft; launcher.setVisible(true)
        workspace.draft = draft; workspace.setVisible(true,in:store)
        store.onHistoryRemoved = { tasks,drafts in launcher.removeHistory(draftIDs:drafts); workspace.removeHistory(taskIDs:tasks,draftIDs:drafts,in:store) }
        workspace.draft = other
        #expect(await intent.perform(in:store))
        #expect(launcher.draft == nil && workspace.draft === other && store.ownsDraft(other))
        let foreign = AIDraftDocument(input:"Synthetic unregistered",actionID:nil,target:nil)
        #expect(await store.closeDraftAndWait(foreign) == false && !foreign.isDiscarded)
        await fixture.cleanup()
    }

    @Test func pendingSuggestionsAreDiscardedButAnOpenedCommandEditorIsKept() async throws {
        try await withStoreHTTPFixture(path:"proposal") { fixture in
            let store = fixture.store, draft = store.createDraft(input:"Synthetic proposal input")
            store.generateCommandProposal(draft:draft)
            let id = try #require(store.tasks.first?.id)
            try await fixture.drain(id)
            #expect(store.pendingCommandReviews.count == 1)
            let review = try #require(store.takeNextCommandReview())
            #expect(store.activeCommandReviews[review.id] != nil)
            store.generateCommandProposal(draft:draft)
            let second = try #require(store.proposalRequests[draft.id]); try await fixture.drain(second)
            #expect(store.pendingCommandReviews.count == 1)
            #expect(await store.closeDraftAndWait(draft))
            #expect(store.pendingCommandReviews.isEmpty && store.activeCommandReviews[review.id]?.command.id == review.command.id)
            #expect(store.tasks.contains(where:{$0.id == id}) && store.tasks.contains(where:{$0.id == second}))
            try fixture.assertNoCommandEffects()
        }
    }
}
