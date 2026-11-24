import Foundation
import Testing
import AICore
import MacAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct AIUsagePresentationTests {
    @Test func sharedRunActionRejectsEmptyForeignAndInFlightDrafts() async throws {
        try await withStoreHTTPFixture(path: "slow") { fixture in
            let store = fixture.store
            let empty = store.createDraft(actionID: fixture.action.id, input: "")
            let foreign = AIDraftDocument(input: "Synthetic foreign draft", actionID: fixture.action.id, target: nil)
            #expect(!store.canRunAIFromInput(empty) && !store.canRunAIFromInput(foreign))
            #expect(store.runAIFromInput(empty) == nil && store.runAIFromInput(foreign) == nil)
            #expect(store.tasks.isEmpty)
            let draft = store.createDraft(actionID: fixture.action.id, input: "Synthetic keyboard action")
            #expect(store.canRunAIFromInput(draft))
            let id = try #require(store.runAIFromInput(draft))
            try await storeEventually { !store.tasks.first(where: { $0.id == id })!.output.isEmpty }
            #expect(!store.canRunAIFromInput(draft) && store.runAIFromInput(draft) == nil)
            #expect(store.tasks.count == 1)
            store.cancelTask(id); try await fixture.drain(id)
            #expect(store.tasks.first { $0.id == id }?.status == .cancelled)
            #expect(store.canRunAIFromInput(draft))
            store.shutdown()
            #expect(!store.canRunAIFromInput(draft) && store.runAIFromInput(draft) == nil)
        }
    }
    @Test func cumulativeFactsKeepMissingValuesUnknownAndReportedZeroDistinct() throws {
        var accumulator = AIUsageAccumulator()
        #expect(AIUsageFacts(accumulator: accumulator, outcome: "succeeded").summary == .unknown)
        let attempt = UUID()
        let first = AIUsage(inputTokens: 12, outputTokens: nil, attemptID: attempt)
        try accumulator.observe(first); try accumulator.observe(first)
        var facts = AIUsageFacts(accumulator: accumulator, outcome: "succeeded")
        #expect(facts.summary.state == .partial && facts.hasUnknownUsage)
        #expect(facts.summary.reportedInputTokens == 12 && facts.summary.reportedOutputTokens == nil)
        #expect(facts.summary.outputText == L("Unknown"))
        try accumulator.observe(.init(inputTokens: 14, outputTokens: 6, attemptID: attempt))
        facts = AIUsageFacts(accumulator: accumulator, outcome: "succeeded")
        #expect(facts.summary.state == .reported && !facts.hasUnknownUsage)
        #expect(facts.summary.reportedInputTokens == 14 && facts.summary.reportedOutputTokens == 6)
        #expect(AIUsageFacts(accumulator: accumulator, outcome: "cancelled").summary.state == .partial)
        var zero = AIUsageAccumulator()
        try zero.observe(.init(inputTokens: 0, outputTokens: 0, attemptID: UUID()))
        let knownZero = AIUsageFacts(accumulator: zero, outcome: "succeeded").summary
        #expect(knownZero.state == .reported && knownZero.reportedInputTokens == 0 && knownZero.reportedOutputTokens == 0)
        #expect(knownZero.costText == L("Cost unknown (no rate configured)"))
    }

    @Test func successfulTextWithoutUsageShowsUnknownInsteadOfZero() async throws {
        try await withStoreHTTPFixture(path: "no-usage") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic no-usage text action")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            #expect(fixture.store.tasks.first { $0.id == id }?.aiUsageSummary?.state == .pending)
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.status == .completed && task.aiUsageSummary == .unknown)
            #expect(task.aiUsageSummary?.inputText == L("Unknown") && task.aiUsageSummary?.outputText == L("Unknown"))
            let receipt = try fixture.usage(id)
            #expect(receipt.hasUnknownUsage && receipt.observations.isEmpty)
        }
    }

    @Test func failedSecondAgentTurnShowsOnlyItsKnownReportedPortion() async throws {
        try await withStoreHTTPFixture(path: "agent-second-turn-failure") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic partial usage agent")
            fixture.store.runReadOnlyAgent(draft: draft)
            let id = try #require(fixture.store.tasks.first?.id)
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            let summary = try #require(task.aiUsageSummary)
            #expect(task.status == .failed && summary.state == .partial)
            #expect(summary.reportedInputTokens == 10 && summary.reportedOutputTokens == 4)
            let receipt = try fixture.usage(id)
            #expect(receipt.hasUnknownUsage && receipt.observations.count == 1)
            #expect(receipt.observations.first?.inputTokens == summary.reportedInputTokens)
            #expect(receipt.observations.first?.outputTokens == summary.reportedOutputTokens)
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 2 && stats["agent_requests"] == 2 && stats["agent_tool_messages"] == 1)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func successfulAgentWithMissingFinalTurnUsageStaysPartialInRuntimeLedgerAndRestart() async throws {
        try await withStoreHTTPFixture(path: "agent-no-final-usage") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic successful agent with one missing usage report")
            fixture.store.runReadOnlyAgent(draft: draft)
            let id = try #require(fixture.store.tasks.first?.id)
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            let live = try #require(task.aiUsageSummary)
            #expect(task.status == .completed && live.state == .partial)
            #expect(live.reportedInputTokens == 10 && live.reportedOutputTokens == 4)
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "succeeded" && receipt.hasUnknownUsage)
            #expect(receipt.observations.count == 1 && receipt.unknownAttempts.count == 1)
            #expect(Set(receipt.observations.map(\.attemptID)).isDisjoint(with: receipt.unknownAttempts))
            #expect(receipt.observations.first?.inputTokens == 10 && receipt.observations.first?.outputTokens == 4)
            var copies = 0
            let restarted = try WorkbenchModel(dataDirectory: fixture.directory, allowContextCapture: false,
                clipboardWriter: { _ in copies += 1 }, clipboardChangeCount: { 0 }, applicationCatalog: ApplicationCatalog(roots: []))
            defer { restarted.shutdown() }
            try await storeEventually { restarted.tasks.first { $0.id == id }?.aiUsageSummary?.state == .partial }
            let restored = try #require(restarted.tasks.first { $0.id == id })
            #expect(restored.aiUsageSummary == live && restored.restoredFromReceipt)
            #expect(restored.output.isEmpty && restarted.taskHandles.isEmpty && copies == 0)
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 2 && stats["agent_requests"] == 2 && stats["agent_tool_messages"] == 1)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func reportedRuntimeUsageRehydratesFromTheSameMetadataWithoutReplay() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic persisted usage")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            try await fixture.drain(id)
            let live = try #require(fixture.store.tasks.first { $0.id == id }?.aiUsageSummary)
            #expect(live.state == .reported && live.reportedInputTokens == 12 && live.reportedOutputTokens == 5)
            var copies = 0
            let restarted = try WorkbenchModel(dataDirectory: fixture.directory, allowContextCapture: false,
                clipboardWriter: { _ in copies += 1 }, clipboardChangeCount: { 0 }, applicationCatalog: ApplicationCatalog(roots: []))
            defer { restarted.shutdown() }
            try await storeEventually { restarted.tasks.first { $0.id == id }?.aiUsageSummary?.state == .reported }
            let restored = try #require(restarted.tasks.first { $0.id == id })
            #expect(restored.aiUsageSummary == live && restored.restoredFromReceipt)
            #expect(restored.output.isEmpty && restarted.taskHandles.isEmpty && copies == 0)
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 1)
        }
    }

    @Test func missingCorruptAndInterruptedMetadataCannotBecomeACompleteZeroCharge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Usage-Metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic-usage.json"), id = UUID(), attempt = UUID()
        #expect(AIUsageLedgerReader.summary(data: try? Data(contentsOf: file), runID: id, interrupted: false) == .unknown)
        try PrivateFiles.write(Data("synthetic-corrupt-json".utf8), to: file)
        #expect(AIUsageLedgerReader.summary(data: try? Data(contentsOf: file), runID: id, interrupted: false) == .unknown)
        let observation: [String: Any] = ["inputTokens": 7, "outputTokens": 3, "attemptID": attempt.uuidString, "counting": "cumulative"]
        let snapshot: [String: Any] = ["runID": id.uuidString, "observations": [observation, observation], "unknownAttempts": [], "hasUnknownUsage": false, "outcome": "succeeded"]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: snapshot), to: file)
        let reported = AIUsageLedgerReader.summary(data: try? Data(contentsOf: file), runID: id, interrupted: false)
        #expect(reported.state == .reported && reported.reportedInputTokens == 7 && reported.reportedOutputTokens == 3)
        let interrupted = AIUsageLedgerReader.summary(data: try? Data(contentsOf: file), runID: id, interrupted: true)
        #expect(interrupted.state == .partial && interrupted.reportedInputTokens == 7)
        #expect(interrupted.costText == L("Cost unknown (no rate configured)"))
        #expect(AIUsageLedgerReader.summary(data: try? Data(contentsOf: file), runID: UUID(), interrupted: false) == .unknown)
    }
}
