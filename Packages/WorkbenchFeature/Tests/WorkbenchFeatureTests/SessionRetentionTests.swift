import Foundation
import Testing
import ExecutionCore
import MacAdapters
import CommandCore
@testable import WorkbenchFeature

@MainActor final class RetentionFixture {
    let directory: URL
    let store: WorkbenchModel
    init(limits: SessionRetentionPolicy = .init(), allowContextCapture: Bool = false, reader: @escaping @MainActor () -> String? = { nil }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Retention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: allowContextCapture, clipboardReader: reader,
            applicationCatalog: ApplicationCatalog(roots: []), sessionLimits: limits)
    }
    func cleanup() async { await store.shutdownAndWait(); try? FileManager.default.removeItem(at: directory) }
}

@Suite(.serialized) @MainActor struct SessionRetentionTests {
    @Test func ninthAIRequestIsRejectedBeforeAnyNetworkOrReceipt() async throws {
        try await withStoreHTTPFixture(path: "slow") { fixture in
            var ids: [UUID] = []
            for _ in 0..<8 {
                let draft = fixture.store.createDraft(input: "Synthetic held request")
                ids.append(try #require(fixture.store.runAI(action: fixture.action, draft: draft)))
            }
            let rejected = fixture.store.createDraft(input: "Synthetic ninth request")
            #expect(fixture.store.runAI(action: fixture.action, draft: rejected) == nil)
            #expect(!rejected.notice.isEmpty && fixture.store.tasks.count == 8)
            #expect(fixture.store.executionReservations.count == 8 && fixture.store.taskHandles.count == 8)
            try await storeEventually { try await fixture.server.stats()["post_requests"] == 8 }
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 8)
            for id in ids { fixture.store.cancelTask(id) }
            for id in ids { try await fixture.drain(id) }
            #expect(fixture.store.executionReservations.isEmpty)
            #expect(await fixture.store.aiInvocationStore.list().count == 8)
        }
    }

    @Test func synchronousWorkspaceReentryCannotBorrowAnUnreservedSlot() async throws {
        let fixture = try RetentionFixture(limits: .init(activeTasks: 1)); defer { Task { await fixture.cleanup() } }
        var reentered = false
        let command = SavedCommand(name: "Synthetic slot", executable: "/usr/bin/printf", arguments: ["synthetic"])
        fixture.store.onOpenWorkspace = { _ in
            guard !reentered else { return }; reentered = true
            fixture.store.runCommand(command)
        }
        fixture.store.runCommand(command)
        #expect(reentered && fixture.store.tasks.count == 1 && fixture.store.executionReservations.count == 1)
        try await storeEventually { fixture.store.taskHandles.isEmpty }
        #expect(await fixture.store.invocationStore.list().count == 1)
        await fixture.cleanup()
    }

    @Test func rejectedLauncherCommandKeepsThePanelAndItsCapacityNotice() async throws {
        let fixture = try RetentionFixture(limits: .init(activeTasks: 1)); defer { Task { await fixture.cleanup() } }
        let command = SavedCommand(name: "Synthetic command", executable: "/usr/bin/printf", arguments: ["synthetic"])
        fixture.store.configuration.savedCommands = [command]
        #expect(fixture.store.runCommand(command, showWorkspace: false) != nil)
        var dismissals = 0
        fixture.store.onDismiss = { _ in dismissals += 1 }
        fixture.store.execute(.init(id: "command." + command.id.uuidString, title: command.name, kind: .command, payload: command.id.uuidString))
        #expect(dismissals == 0 && fixture.store.tasks.count == 1 && !fixture.store.launcherNotice.isEmpty)
        try await storeEventually { fixture.store.taskHandles.isEmpty }
        await fixture.cleanup()
    }

    @Test func visibleDraftsAreProtectedAndRejectedInputDoesNotEvictThem() async throws {
        let fixture = try RetentionFixture(limits: .init(drafts: 2)); defer { Task { await fixture.cleanup() } }
        let first = fixture.store.createDraft(input: "Synthetic first"), second = fixture.store.createDraft(input: "Synthetic second")
        let launcher = LauncherSession(store: fixture.store), workspace = WorkspaceSession()
        launcher.draft = first; launcher.setVisible(true)
        workspace.draft = second; workspace.setVisible(true, in: fixture.store)
        let rejected = fixture.store.createDraft(input: "Synthetic third")
        #expect(rejected.isDiscarded && rejected.input.isEmpty && !fixture.store.ownsDraft(rejected))
        #expect(!fixture.store.workspaceNotice.isEmpty && first.input == "Synthetic first" && second.input == "Synthetic second")
        launcher.setVisible(false)
        let third = fixture.store.createDraft(input: "Synthetic accepted third")
        #expect(fixture.store.ownsDraft(third) && fixture.store.ownsDraft(second))
        #expect(first.isDiscarded && first.input.isEmpty && first.sourceTarget == nil)
        first.editInput("Synthetic stale edit"); first.useClipboard("Synthetic stale clipboard")
        #expect(first.input.isEmpty)
        await fixture.cleanup()
    }

    @Test func oversizedCreationAndEditingKeepExistingInputAndUTF8Boundary() async throws {
        let fixture = try RetentionFixture(limits: .init(drafts: 1)); defer { Task { await fixture.cleanup() } }
        let original = fixture.store.createDraft(input: "Synthetic preserved")
        let tooLong = String(repeating: "汉", count: 43_691)
        let rejected = fixture.store.createDraft(input: tooLong)
        #expect(rejected.isDiscarded && rejected.input.isEmpty && fixture.store.ownsDraft(original))
        original.editInput(tooLong); original.useClipboard(tooLong)
        #expect(original.input == "Synthetic preserved" && !original.notice.isEmpty)
        original.editInput(String(repeating: "a", count: 131_072))
        #expect(original.input.utf8.count == 131_072)
        await fixture.cleanup()
    }

    @Test func completedHandleIsProtectedUntilDurableClosingFinishes() async throws {
        let fixture = try RetentionFixture(limits: .init(tasks: 1)); defer { Task { await fixture.cleanup() } }
        let id = UUID()
        #expect(fixture.store.reserveExecution(id))
        fixture.store.tasks.append(.init(id: id, title: "Synthetic closing", state: .completed, finishedAt: Date()))
        #expect(!fixture.store.makeSessionRoom(taskSlots: 1))
        #expect(fixture.store.tasks.count == 1)
        fixture.store.finishExecutionReservation(id)
        #expect(fixture.store.makeSessionRoom(taskSlots: 1))
        #expect(fixture.store.tasks.isEmpty)
        await fixture.cleanup()
    }

    @Test func globalTextReservationCountsFullOutputsAndExecutionInputSnapshots() async throws {
        let fixture = try RetentionFixture(limits: .init(textBytes: 2_000_000)); defer { Task { await fixture.cleanup() } }
        let first = UUID(), second = UUID()
        #expect(fixture.store.reserveExecution(first))
        fixture.store.tasks.append(.init(id: first, title: "Synthetic active", state: .running))
        let reserved = fixture.store.retainedSessionBytes()
        _ = fixture.store.appendOutput(first, text: String(repeating: "x", count: 1_048_576))
        #expect(fixture.store.retainedSessionBytes() == reserved)
        #expect(!fixture.store.reserveExecution(second))
        #expect(fixture.store.retainedSessionBytes() <= 2_000_000)
        fixture.store.finishExecutionReservation(first)
        await fixture.cleanup()
    }

    @Test func restoredHistoryAndPendingReviewsStayWithinTheirLimits() async throws {
        let fixture = try RetentionFixture(limits: .init(tasks: 3)); defer { Task { await fixture.cleanup() } }
        for offset in 0..<20 {
            let date = Date(timeIntervalSince1970: Double(offset))
            fixture.store.restoreReceipt(.init(id: UUID(), name: "Synthetic receipt", state: .succeeded, startedAt: date, finishedAt: date))
        }
        #expect(fixture.store.tasks.count == 3)
        let reviewFixture = try RetentionFixture(); defer { Task { await reviewFixture.cleanup() } }
        let command = SavedCommand(name: "Synthetic review", executable: "/usr/bin/printf")
        for _ in 0..<10 { try reviewFixture.store.enqueueCommandReview(command, runID: UUID()) }
        #expect(throws: SessionAdmissionError.self) { try reviewFixture.store.enqueueCommandReview(command, runID: UUID()) }
        #expect(reviewFixture.store.pendingCommandReviews.count == 10)
        await fixture.cleanup(); await reviewFixture.cleanup()
    }

    @Test func changingTheRunInsideAVisibleDraftKeepsItsCurrentResultProtected() async throws {
        let fixture = try RetentionFixture(limits: .init(tasks: 2)); defer { Task { await fixture.cleanup() } }
        let current = UUID(), other = UUID(), draft = fixture.store.createDraft(input: "Synthetic visible")
        fixture.store.tasks = [
            .init(id: current, title: "Synthetic visible result", state: .completed, startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date()),
            .init(id: other, title: "Synthetic idle result", state: .completed, startedAt: Date(timeIntervalSince1970: 2), finishedAt: Date())]
        let launcher = LauncherSession(store: fixture.store); launcher.draft = draft; launcher.setVisible(true)
        // 文档对象没有替换；只更新共享文档里的运行选择。
        draft.latestRunID = current
        #expect(fixture.store.makeSessionRoom(taskSlots: 1))
        #expect(fixture.store.tasks.map(\.id) == [current])
        await fixture.cleanup()
    }

    @Test func reviewingACommandKeepsItsBytesAndSlotChargedUntilDismissal() async throws {
        let fixture = try RetentionFixture(limits: .init(textBytes: 1_000_000)); defer { Task { await fixture.cleanup() } }
        let command = SavedCommand(name: "Synthetic large review", executable: "/usr/bin/printf", arguments: [String(repeating: "x", count: 600_000)])
        let first = UUID()
        try fixture.store.enqueueCommandReview(command, runID: first)
        let before = fixture.store.retainedSessionBytes()
        #expect(fixture.store.takeNextCommandReview()?.id == first)
        #expect(fixture.store.retainedSessionBytes() == before && fixture.store.activeCommandReviews.count == 1)
        #expect(throws: SessionAdmissionError.self) { try fixture.store.enqueueCommandReview(command, runID: UUID()) }
        fixture.store.finishCommandReview(first)
        try fixture.store.enqueueCommandReview(command, runID: UUID())
        #expect(fixture.store.pendingCommandReviews.count == 1)
        await fixture.cleanup()
    }
}
