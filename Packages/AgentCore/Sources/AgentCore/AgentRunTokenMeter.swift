import AICore
import ExecutionCore
import Foundation

public enum AgentRunTokenError: Error, Equatable, Sendable { case invalidThreshold, thresholdReached, usageUnavailable }

/// 每run独享；只按有身份的累计快照扣额，不推测下一请求的输入消耗。
public struct AgentRunTokenMeter: Sendable {
    public static let readOnlyThreshold = 32_000
    public let maximumTokens: Int?
    private var accumulator = AIUsageAccumulator()
    private var attempts: Set<UUID> = []
    private var roundAttempt: UUID?
    private var roundOpen = false
    private var invalid = false
    private var turns = 0
    private var state = RunTokenBudgetSnapshot.Status.awaitingUsage
    public init(maximumTokens: Int?) throws {
        guard maximumTokens.map({ (1...RunTokenBudgetSnapshot.maximumThreshold).contains($0) }) ?? true else { throw AgentRunTokenError.invalidThreshold }
        self.maximumTokens = maximumTokens
    }
    private var knownTokens: Int? {
        var result = 0
        for value in accumulator.observations {
            for count in [value.inputTokens, value.outputTokens] {
                let (next, overflow) = result.addingReportingOverflow(count ?? 0)
                guard !overflow else { return nil }; result = next
            }
        }
        return result
    }
    public var snapshot: RunTokenBudgetSnapshot? {
        let total = knownTokens
        let displayed: RunTokenBudgetSnapshot.Status = invalid || total == nil ? .usageUnavailable : state
        return maximumTokens.map { .init(maximumTokens: $0, knownTokens: total, completedTurns: turns, status: displayed) }
    }
    public mutating func beginTurn() throws {
        guard maximumTokens != nil else { return }
        guard !roundOpen, turns < 16, !invalid, state != .usageUnavailable else { throw AgentRunTokenError.usageUnavailable }
        guard state != .thresholdReached else { throw AgentRunTokenError.thresholdReached }
        roundOpen = true; roundAttempt = nil; state = .awaitingUsage
    }
    public mutating func observe(_ usage: AIUsage) {
        guard maximumTokens != nil else { return }
        guard roundOpen else { invalid = true; return }
        if let roundAttempt {
            guard roundAttempt == usage.attemptID else { invalid = true; return }
        } else {
            // 当前conversation每轮一次请求；旧身份不能为新轮提供免费额度。
            guard !attempts.contains(usage.attemptID) else { invalid = true; return }
            roundAttempt = usage.attemptID; attempts.insert(usage.attemptID)
        }
        do { try accumulator.observe(usage) } catch { invalid = true }
    }
    public mutating func finishTurn() {
        guard maximumTokens != nil else { return }
        guard roundOpen else { invalid = true; state = .usageUnavailable; return }
        roundOpen = false; turns += 1
        guard roundAttempt != nil, !invalid, !accumulator.hasUnknownUsage, let total = knownTokens else { state = .usageUnavailable; return }
        state = total >= maximumTokens! ? .thresholdReached : .verified
    }
    public func authorizeContinuation(hasToolCalls: Bool) throws {
        guard let maximumTokens else { return }
        guard !roundOpen, turns > 0, !invalid, state != .usageUnavailable, let total = knownTokens else { throw AgentRunTokenError.usageUnavailable }
        if total > maximumTokens || (total == maximumTokens && hasToolCalls) { throw AgentRunTokenError.thresholdReached }
    }
    public func nextOutputLimit(perRequestLimit: Int) throws -> Int? {
        guard (1...32_768).contains(perRequestLimit) else { throw AgentRunTokenError.invalidThreshold }
        guard let maximumTokens else { return nil }
        guard !roundOpen, !invalid, state != .usageUnavailable, let total = knownTokens else { throw AgentRunTokenError.usageUnavailable }
        guard total < maximumTokens else { throw AgentRunTokenError.thresholdReached }
        return min(perRequestLimit, maximumTokens - total)
    }
}
