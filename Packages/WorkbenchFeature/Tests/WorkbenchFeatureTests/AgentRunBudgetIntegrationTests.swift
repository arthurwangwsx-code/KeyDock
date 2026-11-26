import Foundation
import Testing
import AgentCore
import AICore
import ExecutionCore
import MacAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct AgentRunBudgetIntegrationTests {
    @Test func unsavedThresholdStopsBeforeToolAndKeepsActualUsageOnRestart() async throws {
        try await withStoreHTTPFixture(path: "agent") { f in
            var definition = f.store.configuration.agents[0]; definition.maxRunTokens = 14
            let id = try #require(f.store.runAgent(definition, input: "Synthetic threshold input"))
            try await f.drain(id)
            let task = try #require(f.store.tasks.first { $0.id == id })
            #expect(task.status == .paused && task.runTokenPauseReason == .thresholdReached)
            #expect(task.runTokenBudget == .init(maximumTokens: 14, knownTokens: 14, completedTurns: 1, status: .thresholdReached))
            #expect(task.aiUsageSummary?.state == .reported)
            #expect(task.aiUsageSummary?.reportedInputTokens == 10 && task.aiUsageSummary?.reportedOutputTokens == 4)
            let parent = try #require(await f.store.aiInvocationStore.list().first { $0.id == id })
            #expect(parent.runAttempt == nil && parent.configurationFingerprint == task.agentRunContractFingerprint)
            #expect(parent.runTokenBudget == task.runTokenBudget)
            let tools = await f.store.agentToolStore.list(); #expect(tools.isEmpty)
            var stats = try await f.server.stats()
            #expect(stats["post_requests"] == 1 && stats["agent_tool_messages"] == 0 && stats["agent_initial_max_tokens"] == 14)
            let restarted = try WorkbenchModel(dataDirectory: f.directory, allowContextCapture: false,
                clipboardWriter: { _ in Issue.record("Restored task must not copy") }, clipboardChangeCount: { 0 }, applicationCatalog: ApplicationCatalog(roots: []))
            defer { restarted.shutdown() }
            try await storeEventually { restarted.tasks.first { $0.id == id }?.aiUsageSummary?.state == .reported }
            let restored = try #require(restarted.tasks.first { $0.id == id })
            #expect(restored.status == .paused && restored.runTokenBudget == task.runTokenBudget)
            #expect(restored.output.isEmpty && restarted.taskHandles.isEmpty && restarted.pendingApprovals.isEmpty)
            stats = try await f.server.stats(); #expect(stats["post_requests"] == 1)
            try f.assertNoCommandEffects()
        }
    }

    @Test func nextRequestCapUsesRemainingThresholdAndOvershootRetainsFinalText() async throws {
        try await withStoreHTTPFixture(path: "agent") { f in
            var definition = AgentDefinition(); definition.maxRunTokens = 34
            let id = try #require(f.store.runAgent(definition, input: "Synthetic two-turn task"))
            try await f.drain(id)
            let task = try #require(f.store.tasks.first { $0.id == id })
            #expect(task.status == .paused && task.output.contains("Synthetic read-only tool round-trip complete"))
            #expect(task.runTokenBudget == .init(maximumTokens: 34, knownTokens: 40, completedTurns: 2, status: .thresholdReached))
            #expect(task.aiUsageSummary?.reportedInputTokens == 30 && task.aiUsageSummary?.reportedOutputTokens == 10)
            #expect(task.aiUsageSummary?.state == .reported)
            let stats = try await f.server.stats(), tools = await f.store.agentToolStore.list()
            #expect(stats["post_requests"] == 2 && stats["agent_tool_messages"] == 1)
            #expect(stats["agent_initial_max_tokens"] == 34 && stats["agent_followup_max_tokens"] == 20)
            #expect(tools.count == 1 && tools[0].configurationFingerprint == task.agentRunContractFingerprint)
            try f.assertNoCommandEffects()
            await f.store.clearAIUsageHistory()
            let cleared = try #require(f.store.tasks.first { $0.id == id })
            #expect(cleared.aiUsageSummary == .unknown && cleared.runTokenBudget?.knownTokens == nil)
            #expect(cleared.runTokenBudget?.maximumTokens == 34 && cleared.runTokenBudget?.status == .usageUnavailable)
            let receipt = try #require(await f.store.aiInvocationStore.list().first { $0.id == id })
            #expect(receipt.runTokenBudget == cleared.runTokenBudget)
        }
    }

    @Test func missingUsagePausesFinalTextAndBuiltInUsesFixedLimit() async throws {
        try await withStoreHTTPFixture(path: "no-usage") { f in
            let draft = f.store.createDraft(input: "Synthetic missing usage")
            f.store.runReadOnlyAgent(draft: draft)
            let id = try #require(f.store.tasks.first?.id); try await f.drain(id)
            let task = try #require(f.store.tasks.first { $0.id == id })
            #expect(task.status == .paused && task.runTokenPauseReason == .usageUnavailable)
            #expect(task.runTokenBudget?.maximumTokens == 32000 && task.runTokenBudget?.status == .usageUnavailable)
            #expect(task.output == "Synthetic no-usage result" && task.aiUsageSummary?.state == .unknown)
            let stats = try await f.server.stats(); #expect(stats["post_requests"] == 1)
            try f.assertNoCommandEffects()
        }
    }

    @Test func productionResponsesLoopbackPreservesOpaqueHistoryWhileReducingOnlyOutputCap() async throws {
        try await withStoreHTTPFixture(path: "responses-agent-budget") { f in
            f.store.configuration.aiModelSettings = AIModelSettings(defaults: .init(requestProtocol: .responses, reasoning: .low, maxOutputTokens: 2048), allowsUnverifiedReasoning: true,
                reasoningServiceFingerprint: AIServiceIdentity.fingerprint(URL(string: f.store.configuration.endpoint)!))
            var definition = AgentDefinition(); definition.maxRunTokens = 34
            let id = try #require(f.store.runAgent(definition, input: "Synthetic Responses task")); try await f.drain(id)
            let task = try #require(f.store.tasks.first { $0.id == id })
            #expect(task.status == .paused && task.runTokenBudget?.knownTokens == 40)
            #expect(task.output.contains("Synthetic Responses budget complete") && !task.output.contains("Synthetic commentary"))
            let stats = try await f.server.stats()
            #expect(stats["post_requests"] == 2 && stats["agent_tool_messages"] == 1)
            #expect(stats["agent_initial_max_tokens"] == 34 && stats["agent_followup_max_tokens"] == 20)
            #expect(task.aiUsageSummary?.state == .reported)
            try f.assertNoCommandEffects()
        }
    }

    @Test func profileEditCannotChangePendingContractAndLateApprovalCannotRunAfterPause() async throws {
        try await withStoreHTTPFixture(path: "agent-command") { f in
            let command = SavedCommand(name: "Synthetic approved command", executable: "/usr/bin/printf", arguments: ["%s", "synthetic"], workingDirectory: f.directory.path)
            f.store.configuration.savedCommands = [command]
            var definition = AgentDefinition(); definition.allowedCommandIDs = [command.id]; definition.maxRunTokens = 100
            f.store.configuration.agents = [definition]
            let id = try #require(f.store.runAgent(definition, input: "Synthetic approval task"))
            try await storeEventually { f.store.pendingApprovals.contains { $0.runID == id } }
            let proposal = try #require(f.store.pendingApprovals.first { $0.runID == id })
            let original = try #require(f.store.tasks.first { $0.id == id }?.agentRunContractFingerprint)
            definition.maxRunTokens = 200; #expect(f.store.saveAgent(definition))
            #expect(proposal.maxRunTokens == 100 && proposal.runContractFingerprint == original)
            #expect(f.store.tasks.first { $0.id == id }?.runTokenBudget?.maximumTokens == 100)
            f.store.pauseAgent(id); f.store.resolveApproval(proposal.id, approved: true)
            try await f.drain(id)
            #expect(f.store.tasks.first { $0.id == id }?.status == .paused)
            let invocations = await f.store.invocationStore.list(); #expect(invocations.isEmpty)
            let stats = try await f.server.stats(); #expect(stats["post_requests"] == 1 && stats["agent_tool_messages"] == 0)
        }
    }

    @Test func partialRecorderFinalizationCannotKeepVerifiedRemainingQuota() async throws {
        try await withStoreHTTPFixture(path: "usage") { f in
            let id = UUID()
            var row = RunningTaskItem(id: id, title: "Synthetic cancelled", state: .cancelled)
            row.runTokenBudget = .init(maximumTokens: 100, knownTokens: 14, completedTurns: 1, status: .verified)
            row.aiUsageSummary = .init(state: .partial, reportedInputTokens: 17, reportedOutputTokens: 4)
            f.store.tasks = [row]; f.store.finalizeRunTokenBudget(id)
            #expect(f.store.tasks[0].runTokenBudget == .init(maximumTokens: 100, knownTokens: 21, completedTurns: 1, status: .usageUnavailable))
        }
    }
}
