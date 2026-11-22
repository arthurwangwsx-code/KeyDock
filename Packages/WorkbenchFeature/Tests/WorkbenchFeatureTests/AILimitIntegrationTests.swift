import Foundation
import Testing
import ExecutionCore
@testable import WorkbenchFeature

enum AIEntry: CaseIterable { case text, proposal, agent }

/// 验证宿主预算和副作用门槛；全部正文合成，clipboard writer 只写内存 spy。
@Suite(.serialized) @MainActor struct AILimitIntegrationTests {
    @Test func emptyTextResponseCannotClearTheClipboard() async throws {
        var writes: [String] = []
        try await withStoreHTTPFixture(path: "empty", clipboardWriter: { writes.append($0) }) { fixture in
            var action = fixture.action; action.output = .copy
            let draft = fixture.store.createDraft(input: "Synthetic nonempty input")
            let id = try #require(fixture.store.runAI(action: action, draft: draft))
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.status == .failed && task.output.isEmpty && !task.notice.isEmpty)
            #expect(writes.isEmpty && !fixture.store.canReplaceResult(id))
        }
    }

    @Test(arguments: AIEntry.allCases) func everyAIEntryRejectsWhitespaceAndOversizedUTF8BeforeCreatingTask(_ entry: AIEntry) async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store
            // 43691 个三字节字符共 131073 字节，防止误用字符数作为上限。
            for input in [" \n\t", String(repeating: "汉", count: 43_691)] {
                let draft = store.createDraft(input: input)
                switch entry {
                case .text: #expect(store.runAI(action: fixture.action, draft: draft) == nil)
                case .proposal: store.generateCommandProposal(draft: draft)
                case .agent: store.runReadOnlyAgent(draft: draft)
                }
                #expect(store.tasks.isEmpty && store.taskHandles.isEmpty)
                #expect(!draft.notice.isEmpty)
            }
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 0)
        }
    }

    @Test func inclusiveInputBoundarySucceedsAndCopyWriterReceivesCompleteResultOnce() async throws {
        var copied: [String] = []
        try await withStoreHTTPFixture(path: "stream", clipboardWriter: { copied.append($0) }) { fixture in
            var action = fixture.action; action.output = .copy
            let input = String(repeating: "汉", count: 43_690) + "ab"
            #expect(input.utf8.count == 131_072)
            let draft = fixture.store.createDraft(input: input)
            let id = try #require(fixture.store.runAI(action: action, draft: draft))
            try await fixture.drain(id)
            #expect(fixture.store.tasks.first { $0.id == id }?.status == .completed)
            #expect(copied == ["你好，网络 🌍"])
        }
    }

    @Test func aSingleOversizedDeltaCannotExceedBudgetOrSplitUTF8() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store, first = UUID(), second = UUID()
            store.tasks = [RunningTaskItem(id: first, title: "Synthetic output", state: .running),
                           RunningTaskItem(id: second, title: "Synthetic output", state: .running)]
            #expect(store.appendOutput(first, text: String(repeating: "a", count: 1_048_574)))
            #expect(!store.appendOutput(first, text: "🌍z"))
            let firstTask = try #require(store.tasks.first { $0.id == first })
            #expect(firstTask.output.utf8.count == 1_048_574 && firstTask.outputIsIncomplete)
            #expect(!firstTask.output.contains("�"))
            #expect(!store.appendOutput(second, text: String(repeating: "汉", count: 400_000)))
            let secondTask = try #require(store.tasks.first { $0.id == second })
            #expect(secondTask.output.utf8.count == 1_048_575 && secondTask.outputIsIncomplete)
            #expect(secondTask.output.allSatisfy { $0 == "汉" })
        }
    }

    @Test func oversizedTextFailsExplicitlyAndNeverAutomaticallyCopies() async throws {
        var copied: [String] = []
        try await withStoreHTTPFixture(path: "large-text", clipboardWriter: { copied.append($0) }) { fixture in
            var action = fixture.action; action.output = .copy
            let draft = fixture.store.createDraft(input: "Synthetic long output request")
            let id = try #require(fixture.store.runAI(action: action, draft: draft))
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.status == .failed && task.outputIsIncomplete && task.finishedAt != nil)
            #expect(task.output.utf8.count <= 1_048_576 && !task.output.isEmpty)
            #expect(!task.notice.isEmpty && !draft.notice.isEmpty)
            #expect(copied.isEmpty && !fixture.store.canReplaceResult(id))
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "failed")
        }
    }

    @Test func agentBudgetAppliesAcrossTurnsAndRetainsPartialUnknownUsage() async throws {
        try await withStoreHTTPFixture(path: "large-agent") { fixture in
            let store = fixture.store
            let draft = store.createDraft(input: "Synthetic tool loop with long output")
            store.runReadOnlyAgent(draft: draft)
            let id = try #require(store.tasks.first?.id)
            try await fixture.drain(id)
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .failed && task.outputIsIncomplete && task.finishedAt != nil)
            #expect(task.output.utf8.count <= 1_048_576 && !task.notice.isEmpty)
            let stats = try await fixture.server.stats()
            #expect(stats["limit_agent_requests"] == 2)
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "failed" && receipt.hasUnknownUsage)
            #expect(receipt.observations.count == 1)
            #expect(receipt.observations.first?.inputTokens == 10)
            #expect(receipt.observations.first?.outputTokens == 4)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func oversizedCommandProposalCannotBecomeReviewableDraft() async throws {
        try await withStoreHTTPFixture(path: "large-proposal") { fixture in
            let store = fixture.store
            var reviewCount = 0
            store.onReviewCommand = { _ in reviewCount += 1 }
            let draft = store.createDraft(input: "Synthetic oversized proposal request")
            store.generateCommandProposal(draft: draft)
            let id = try #require(store.proposalRequests[draft.id])
            try await fixture.drain(id)
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .failed && task.outputIsIncomplete && task.output.utf8.count <= 1_048_576)
            #expect(reviewCount == 0 && !task.notice.isEmpty)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func newDraftCopyRequestPreventsOlderDraftFromOverwritingClipboard() async throws {
        var copied: [String] = []
        try await withStoreHTTPFixture(path: "held-text", clipboardWriter: { copied.append($0) }) { fixture in
            let store = fixture.store
            var action = fixture.action; action.output = .copy
            let firstDraft = store.createDraft(input: "Synthetic older shortcut")
            let first = try #require(store.runAI(action: action, draft: firstDraft))
            try await storeEventually { try await fixture.server.stats()["held_text_started"] == 1 }
            store.configuration.endpoint = fixture.server.endpoint("stream")
            let secondDraft = store.createDraft(input: "Synthetic newer shortcut")
            let second = try #require(store.runAI(action: action, draft: secondDraft))
            try await fixture.drain(second)
            #expect(copied == ["你好，网络 🌍"])
            try await releaseText(fixture.server)
            try await fixture.drain(first)
            #expect(copied == ["你好，网络 🌍"])
            #expect(store.tasks.first { $0.id == first }?.status == .completed)
            #expect(store.tasks.first { $0.id == first }?.output == "Synthetic held result")
        }
    }

    @Test func userClipboardChangeKeepsCompletedResultWithoutOverwritingTheNewContent() async throws {
        var copied: [String] = []
        var changeCount = 7
        try await withStoreHTTPFixture(path: "held-text", clipboardWriter: { copied.append($0) }, clipboardChangeCount: { changeCount }) { fixture in
            let store = fixture.store
            var action = fixture.action; action.output = .copy
            let draft = store.createDraft(input: "Synthetic selected input")
            let id = try #require(store.runAI(action: action, draft: draft))
            try await storeEventually { try await fixture.server.stats()["held_text_started"] == 1 }
            // 只改变合成 metadata，代表请求期间用户复制了新内容；没有读写系统剪贴板。
            changeCount += 1
            try await releaseText(fixture.server)
            try await fixture.drain(id)
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .completed && !task.outputIsIncomplete)
            #expect(task.output == "Synthetic held result" && copied.isEmpty)
            #expect(!task.notice.isEmpty && draft.notice == task.notice)
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "succeeded")
        }
    }

    @Test func editingInputAndCancellationBothPreventPendingAutomaticCopy() async throws {
        for cancel in [false, true] {
            var copied: [String] = []
            try await withStoreHTTPFixture(path: "held-text", clipboardWriter: { copied.append($0) }) { fixture in
                let store = fixture.store
                var action = fixture.action; action.output = .copy
                let draft = store.createDraft(input: "Synthetic pending copy")
                let id = try #require(store.runAI(action: action, draft: draft))
                try await storeEventually { try await fixture.server.stats()["held_text_started"] == 1 }
                if cancel { store.cancelTask(id) } else { draft.editInput("Synthetic changed input") }
                try await releaseText(fixture.server)
                try await fixture.drain(id)
                #expect(copied.isEmpty)
                #expect(store.tasks.first { $0.id == id }?.status == (cancel ? .cancelled : .completed))
            }
        }
    }

    @Test func truncatedCLIStillDrainsAndFinishesWithoutLosingItsWarningOrStderr() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            // 无 shell、无个人文件和环境读取；只向 stdout/stderr 写合成字节。
            let script = "import os; os.write(1,b'x'*700000); os.write(2,b'synthetic stderr tail')"
            let command = SavedCommand(name: "Synthetic bounded CLI", executable: "/usr/bin/python3", arguments: ["-I", "-c", script], workingDirectory: fixture.directory.path)
            fixture.store.runCommand(command, showWorkspace: false)
            let id = try #require(fixture.store.tasks.first?.id)
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.status == .completed && task.exitCode == 0 && task.finishedAt != nil)
            #expect(task.outputIsIncomplete && !task.notice.isEmpty)
            #expect(task.output.utf8.count <= 1_048_576 && task.output.contains("synthetic stderr tail"))
            let receipts = await fixture.store.invocationStore.list()
            #expect(receipts.count == 1 && receipts.first?.state == .succeeded)
        }
    }

    private func releaseText(_ server: StoreSSEServer) async throws {
        let request = URLRequest(url: server.baseURL.appendingPathComponent("release-text"), timeoutInterval: 2)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
