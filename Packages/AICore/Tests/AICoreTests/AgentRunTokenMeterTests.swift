import Foundation
import Testing
import AgentCore
import ExecutionCore
@testable import AICore

@Suite struct AgentRunTokenMeterTests {
    @Test func partialCompletionAndDuplicatesChargeEachRequestOnce() throws {
        var meter = try AgentRunTokenMeter(maximumTokens: 100)
        #expect(try meter.nextOutputLimit(perRequestLimit: 2048) == 100)
        try meter.beginTurn()
        let first = UUID()
        meter.observe(.init(inputTokens: 10, outputTokens: nil, attemptID: first))
        meter.observe(.init(inputTokens: nil, outputTokens: 20, attemptID: first, responseID: "response-1"))
        meter.observe(.init(inputTokens: 10, outputTokens: 20, attemptID: first, responseID: "response-1"))
        meter.finishTurn(); try meter.authorizeContinuation(hasToolCalls: true)
        #expect(meter.snapshot?.knownTokens == 30 && meter.snapshot?.status == .verified)
        #expect(try meter.nextOutputLimit(perRequestLimit: 80) == 70)
        try meter.beginTurn()
        meter.observe(.init(inputTokens: 30, outputTokens: 10, attemptID: UUID(), responseID: "response-1"))
        meter.finishTurn(); try meter.authorizeContinuation(hasToolCalls: true)
        #expect(meter.snapshot?.knownTokens == 70 && meter.snapshot?.completedTurns == 2)
        #expect(try meter.nextOutputLimit(perRequestLimit: 2048) == 30)
    }
    @Test(arguments: ["missing", "partial", "negative", "delta", "conflict", "decrease", "overflow", "two-identities"])
    func unverifiedUsageNeverProvidesAnotherQuota(_ mode: String) throws {
        var meter = try AgentRunTokenMeter(maximumTokens: 100)
        try meter.beginTurn(); let id = UUID()
        switch mode {
        case "missing": break
        case "partial": meter.observe(.init(inputTokens: 1, outputTokens: nil, attemptID: id))
        case "negative": meter.observe(.init(inputTokens: -1, outputTokens: 1, attemptID: id))
        case "delta": meter.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: id, counting: .delta))
        case "conflict":
            meter.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: id, responseID: "a"))
            meter.observe(.init(inputTokens: 2, outputTokens: 1, attemptID: id, responseID: "b"))
        case "decrease":
            meter.observe(.init(inputTokens: 2, outputTokens: 2, attemptID: id))
            meter.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: id))
        case "overflow": meter.observe(.init(inputTokens: Int.max, outputTokens: 1, attemptID: id))
        default:
            meter.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: id))
            meter.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: UUID()))
        }
        // 后续完整值不能清除已发现冲突，但合法partial仍在其他测试中允许补齐。
        if !["missing", "partial", "overflow"].contains(mode) { meter.observe(.init(inputTokens: 2, outputTokens: 2, attemptID: id)) }
        meter.finishTurn()
        #expect(meter.snapshot?.status == .usageUnavailable && meter.snapshot?.isValid == true)
        #expect(throws: AgentRunTokenError.usageUnavailable) { try meter.authorizeContinuation(hasToolCalls: false) }
        #expect(throws: AgentRunTokenError.usageUnavailable) { try meter.nextOutputLimit(perRequestLimit: 2048) }
    }
    @Test func exactThresholdCanFinishButCannotDispatchToolAndOvershootPauses() throws {
        for total in [100, 101] {
            var meter = try AgentRunTokenMeter(maximumTokens: 100)
            try meter.beginTurn(); meter.observe(.init(inputTokens: total - 1, outputTokens: 1, attemptID: UUID())); meter.finishTurn()
            #expect(meter.snapshot?.status == .thresholdReached)
            #expect(throws: AgentRunTokenError.thresholdReached) { try meter.authorizeContinuation(hasToolCalls: true) }
            if total == 100 { try meter.authorizeContinuation(hasToolCalls: false) }
            else { #expect(throws: AgentRunTokenError.thresholdReached) { try meter.authorizeContinuation(hasToolCalls: false) } }
            #expect(throws: AgentRunTokenError.thresholdReached) { try meter.nextOutputLimit(perRequestLimit: 20) }
        }
    }
    @Test func reusedAttemptAcrossTurnsCannotHideAnExtraRequest() throws {
        var meter = try AgentRunTokenMeter(maximumTokens: 100)
        let id = UUID(); try meter.beginTurn()
        meter.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: id)); meter.finishTurn()
        try meter.beginTurn(); meter.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: id)); meter.finishTurn()
        #expect(meter.snapshot?.knownTokens == 2 && meter.snapshot?.status == .usageUnavailable)
        #expect(throws: AgentRunTokenError.usageUnavailable) { try meter.authorizeContinuation(hasToolCalls: true) }
    }
    @Test func separateRunsDoNotShareQuotaAndDisabledThresholdPreservesUnknownUsageBehavior() throws {
        var first = try AgentRunTokenMeter(maximumTokens: 10), second = try AgentRunTokenMeter(maximumTokens: 10)
        try first.beginTurn(); first.observe(.init(inputTokens: 10, outputTokens: 0, attemptID: UUID())); first.finishTurn()
        #expect(try second.nextOutputLimit(perRequestLimit: 10) == 10)
        try second.beginTurn(); second.observe(.init(inputTokens: 1, outputTokens: 1, attemptID: UUID())); second.finishTurn()
        try second.authorizeContinuation(hasToolCalls: true)
        var disabled = try AgentRunTokenMeter(maximumTokens: nil)
        try disabled.beginTurn(); disabled.finishTurn(); try disabled.authorizeContinuation(hasToolCalls: true)
        #expect(disabled.snapshot == nil)
        #expect(try disabled.nextOutputLimit(perRequestLimit: 2048) == nil)
    }
    @Test func invalidThresholdsAndCorruptPersistedSnapshotsAreRejected() throws {
        for value in [0, -1, RunTokenBudgetSnapshot.maximumThreshold + 1] {
            #expect(throws: AgentRunTokenError.invalidThreshold) { try AgentRunTokenMeter(maximumTokens: value) }
        }
        let snapshot = RunTokenBudgetSnapshot(maximumTokens: 100, knownTokens: 15, completedTurns: 1, status: .verified)
        #expect(try JSONDecoder().decode(RunTokenBudgetSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        for invalid in [RunTokenBudgetSnapshot(maximumTokens: 0), .init(maximumTokens: 10, knownTokens: 11, status: .verified), .init(maximumTokens: 10, knownTokens: nil)] {
            #expect(!invalid.isValid)
            #expect(throws: (any Error).self) { try JSONEncoder().encode(invalid) }
        }
    }
    @Test(arguments: ["at-line", "overflow", "outside-turn"])
    func intermediateFactsAlwaysProduceAValidCodableSnapshot(_ mode: String) throws {
        var meter = try AgentRunTokenMeter(maximumTokens: 10)
        #expect(throws: AgentRunTokenError.usageUnavailable) { try meter.authorizeContinuation(hasToolCalls: true) }
        if mode != "outside-turn" { try meter.beginTurn() }
        meter.observe(.init(inputTokens: mode == "overflow" ? Int.max : 10, outputTokens: mode == "overflow" ? 1 : 0, attemptID: UUID()))
        let snapshot = try #require(meter.snapshot)
        #expect(snapshot.isValid)
        #expect(try JSONDecoder().decode(RunTokenBudgetSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        #expect(snapshot.status == (mode == "at-line" ? .awaitingUsage : .usageUnavailable))
    }
}
