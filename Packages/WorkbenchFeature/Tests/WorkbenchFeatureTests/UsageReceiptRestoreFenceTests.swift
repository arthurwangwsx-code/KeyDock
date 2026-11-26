import Foundation
import Darwin
import Testing
import AgentCore
import AICore
import ExecutionCore
@testable import WorkbenchFeature

private actor UsageRestoreReadCounter {
    private(set) var reads = 0
    func direct() -> AIUsageMetadataReadResult {
        reads += 1; return .init(data: nil, problem: nil, revision: 0)
    }
    func family() -> WorkflowUsageRead {
        reads += 1; return .init(revision: 0, recorded: .init(incomplete: true), links: [])
    }
}

private enum UsageReadOrigin: CaseIterable { case missing, foreign, duringClear, fresh }

private final class UsageRestoreWriteGate: @unchecked Sendable {
    private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var holdCLI = false, insideCLI = false, failAI = false, aiFailures = 0
    func holdNextCLIWrite() { lock.withLock { holdCLI = true } }
    func failNextAIWrite() { lock.withLock { failAI = true } }
    var entered: Bool { lock.withLock { insideCLI } }
    var failureCount: Int { lock.withLock { aiFailures } }
    func release() { signal.signal() }
    func code(_ domain: String, _ point: InvocationPersistencePoint) -> Int32? {
        guard point == .beforeWrite else { return nil }
        let action: (Bool, Int32?) = lock.withLock {
            if domain == "cli", holdCLI { holdCLI = false; insideCLI = true; return (true, nil) }
            if domain == "ai", failAI { failAI = false; aiFailures += 1; return (false, EIO) }
            return (false, nil)
        }
        if action.0, signal.wait(timeout: .now() + 5) == .timedOut { return ETIMEDOUT }
        return action.1
    }
}

@MainActor private func seedOwnedBudget(_ store: WorkbenchModel) async throws -> InvocationReceipt {
    let id = UUID()
    var agent = AgentDefinition(); agent.name = "Synthetic usage restoration"; agent.maxRunTokens = 100
    #expect(store.saveAgent(agent))
    agent = try #require(store.configuration.agents.first { $0.id == agent.id })
    let begun = try await store.aiInvocationStore.begin(id: id, name: AITaskReceiptKind.agent.rawValue,
        runDefinition: SavedRunDefinition.agent(agent).reference, runTokenBudget: .init(maximumTokens: 100))
    let budget = RunTokenBudgetSnapshot(maximumTokens: 100, knownTokens: 31, completedTurns: 2, status: .verified)
    try await store.aiInvocationStore.finish(id: id, result: .init(state: .succeeded), runTokenBudget: budget, expectedRunStamp: begun.runStamp)
    await store.aiInvocationStore.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
    return try #require(await store.aiInvocationStore.list().first { $0.id == id })
}

@Suite(.serialized) @MainActor struct UsageReceiptRestoreFenceTests {
    @Test func cachedReceiptCannotRestoreClearedBudgetConsumption() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, id = UUID()
            var agent = AgentDefinition(); agent.name = "Synthetic usage restoration"; agent.maxRunTokens = 100
            #expect(store.saveAgent(agent))
            agent = try #require(store.configuration.agents.first { $0.id == agent.id })
            let begun = try await store.aiInvocationStore.begin(id: id, name: AITaskReceiptKind.agent.rawValue,
                runDefinition: SavedRunDefinition.agent(agent).reference, runTokenBudget: .init(maximumTokens: 100))
            let budget = RunTokenBudgetSnapshot(maximumTokens: 100, knownTokens: 31, completedTurns: 2, status: .verified)
            try await store.aiInvocationStore.finish(id: id, result: .init(state: .succeeded), runTokenBudget: budget, expectedRunStamp: begun.runStamp)
            await store.aiInvocationStore.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
            let old = try #require(await store.aiInvocationStore.list().first { $0.id == id })
            let history = store.historyGeneration
            let usageRead = store.captureUsageRestoreRead()
            await store.clearAIUsageHistory()
            let disk = try #require(await store.aiInvocationStore.list().first { $0.id == id })
            #expect(disk.runTokenBudget?.knownTokens == nil && disk.runTokenBudget?.completedTurns == 0)
            #expect(disk.runAttempt == old.runAttempt && disk.runTokenBudget?.maximumTokens == 100)
            // 模拟尚未发布的缓存读取；不让已有UI行的去重掩盖恢复入口的时序问题。
            store.tasks.removeAll { $0.id == id }
            store.restoreHistorySnapshot(cli: [], ai: [old], generation: history, usageRead: usageRead)
            let restored = try #require(store.tasks.first { $0.id == id })
            #expect(restored.runTokenBudget?.knownTokens == nil)
            #expect(restored.runTokenBudget?.completedTurns == 0 && restored.runTokenBudget?.status == .usageUnavailable)
            #expect(restored.runTokenBudget?.maximumTokens == 100 && restored.runAttempt == old.runAttempt)
            #expect(restored.status == .completed && restored.output.isEmpty && restored.restoredFromReceipt)
            #expect(store.taskHandles.isEmpty && store.executionReservations.isEmpty && store.pendingApprovals.isEmpty)
        }
    }

    @Test(arguments: UsageReadOrigin.allCases)
    private func receiptRecoveryRequiresItsOwnFreshRead(_ origin: UsageReadOrigin) async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, id = UUID()
            let budget = RunTokenBudgetSnapshot(maximumTokens: 100, knownTokens: 31, completedTurns: 2, status: .verified)
            let receipt = InvocationReceipt(id: id, name: AITaskReceiptKind.agent.rawValue, state: .succeeded, finishedAt: Date(), runTokenBudget: budget)
            let ticket: UsageRestoreReadTicket?
            switch origin {
            case .missing: ticket = nil
            case .foreign: ticket = UsageRestoreReadFence().capture(generation: store.usageHistoryGeneration, isClearing: false)
            case .duringClear:
                store.isClearingUsage = true
                ticket = store.captureUsageRestoreRead()
                store.isClearingUsage = false
            case .fresh: ticket = store.captureUsageRestoreRead()
            }
            if origin == .missing { store.restoreAIReceipt(receipt) }
            else { store.restoreHistorySnapshot(cli: [], ai: [receipt], generation: store.historyGeneration, usageRead: ticket) }
            let restored = try #require(store.tasks.first { $0.id == id })
            #expect(restored.status == .completed && restored.runTokenBudget?.maximumTokens == 100)
            if origin == .fresh { #expect(restored.runTokenBudget == budget) }
            else {
                #expect(restored.runTokenBudget?.knownTokens == nil && restored.runTokenBudget?.completedTurns == 0)
                #expect(restored.runTokenBudget?.status == .usageUnavailable)
            }
            #expect(store.taskHandles.isEmpty && store.executionReservations.isEmpty && store.pendingApprovals.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func ledgerReadCreatedDuringClearCannotBecomeValidAfterClearEnds(_ workflow: Bool) async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, id = UUID(), counter = UsageRestoreReadCounter()
            store.isClearingUsage = true
            let kind: AITaskReceiptKind = workflow ? .workflow : .text
            store.restoreAIReceipt(.init(id: id, name: kind.rawValue, state: .succeeded, finishedAt: Date()))
            let read: Task<Void, Never>
            if workflow { read = store.loadRestoredWorkflowUsage(id, reader: { await counter.family() }) }
            else { read = store.loadRestoredAIUsage(id, interrupted: false, reader: { await counter.direct() }) }
            // 不等待Task开始，模拟清除中取得的工作直到清除结束才被调度。
            store.isClearingUsage = false
            await read.value
            let calls = await counter.reads; #expect(calls == 0)
            #expect(store.tasks.first { $0.id == id }?.aiUsageSummary == .unknown)
        }
    }

    @Test func newReceiptReadAfterClearCanPublishNewConsumption() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let before = try await seedOwnedBudget(store)
            await store.clearAIUsageHistory()
            let after = try await seedOwnedBudget(store)
            let usageRead = store.captureUsageRestoreRead()
            let snapshot = await store.aiInvocationStore.list()
            store.tasks.removeAll { $0.id == before.id || $0.id == after.id }
            store.restoreHistorySnapshot(cli: [], ai: snapshot, generation: store.historyGeneration, usageRead: usageRead)
            let previous = try #require(store.tasks.first { $0.id == before.id })
            let newest = try #require(store.tasks.first { $0.id == after.id })
            #expect(previous.runTokenBudget?.knownTokens == nil && previous.runTokenBudget?.completedTurns == 0)
            #expect(newest.runTokenBudget == after.runTokenBudget && newest.runTokenBudget?.knownTokens == 31)
            #expect(newest.runAttempt == after.runAttempt && previous.runAttempt == before.runAttempt)
        }
    }

    @Test func failedHistoryGroupCannotRestorePreUsageClearBudget() async throws {
        let gate = UsageRestoreWriteGate()
        let fixture = try WorkflowIntegrationFixture(invocationPersistenceFault: { gate.code($0, $1) })
        await fixture.stopAutomaticWork()
        do {
            let store = fixture.store, cli = UUID()
            try await store.invocationStore.begin(id: cli, name: "Synthetic clear scheduling gate")
            try await store.invocationStore.finish(id: cli, result: .init(state: .succeeded))
            await store.invocationStore.releaseProtection(for: cli)
            let original = try await seedOwnedBudget(store)
            gate.holdNextCLIWrite()
            let clearing = Task { await store.clearFinishedHistory() }
            do {
                try await fixture.eventually { gate.entered }
                // 此时生产函数已读取内部旧snapshot／ticket，但尚未恢复失败组。
                store.tasks.removeAll { $0.id == original.id }
                await store.clearAIUsageHistory()
                let disk = try #require(await store.aiInvocationStore.list().first { $0.id == original.id })
                #expect(disk.runTokenBudget?.knownTokens == nil && disk.runAttempt == original.runAttempt)
                let diskFile = fixture.directory.appendingPathComponent("ai-invocations/invocations.json")
                let clearedBytes = try Data(contentsOf: diskFile)
                gate.failNextAIWrite(); gate.release()
                await clearing.value
                let restored = try #require(store.tasks.first { $0.id == original.id })
                #expect(restored.restoredFromReceipt && restored.runAttempt == original.runAttempt)
                #expect(restored.runTokenBudget?.knownTokens == nil && restored.runTokenBudget?.completedTurns == 0)
                #expect(restored.runTokenBudget?.status == .usageUnavailable && restored.runTokenBudget?.maximumTokens == 100)
                #expect(restored.aiUsageSummary == .unknown && restored.status == .completed && gate.failureCount == 1)
                #expect(try Data(contentsOf: diskFile) == clearedBytes)
                #expect(!store.settingsNotice.isEmpty && store.taskHandles.isEmpty && store.pendingApprovals.isEmpty)
                let remaining = await store.aiInvocationStore.list(); #expect(remaining.map(\.id) == [original.id])
                let cliRows = await store.invocationStore.list(); #expect(cliRows.isEmpty)
            } catch { gate.release(); await clearing.value; throw error }
            await fixture.cleanup()
        } catch { gate.release(); await fixture.cleanup(); throw error }
    }
}
