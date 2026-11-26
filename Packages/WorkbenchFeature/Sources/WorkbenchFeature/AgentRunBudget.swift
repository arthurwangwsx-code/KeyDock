import Foundation
import AgentCore
import AICore
import ExecutionCore

struct FrozenAgentRunContract: Sendable {
    let fingerprint: String
    let maxRunTokens: Int?
    let perRequestOutputLimit: Int
    var initialBudget: RunTokenBudgetSnapshot? { maxRunTokens.map { .init(maximumTokens: $0) } }
}
enum ReadOnlyAgentLimits { static let calls = 2, turns = 3, seconds = 120 }
extension WorkbenchModel {
    func freezeAgentRunContract(_ definition: AgentDefinition?, settings: FrozenAIExecutionSettings) throws -> FrozenAgentRunContract {
        struct Seed: Encodable {
            let policyVersion: Int
            let definitionFingerprint: String
            let modelSettingsFingerprint: String
            let maxRunTokens: Int?
            let perRequestOutputLimit: Int
        }
        let reference: String, threshold: Int?
        if let definition {
            reference = try RunDefinitionFingerprint.reference(definition).fingerprint; threshold = definition.maxRunTokens
        } else {
            reference = "builtin.current-time.readonly.1|\(ReadOnlyAgentLimits.calls)|\(ReadOnlyAgentLimits.turns)|\(ReadOnlyAgentLimits.seconds)"
            threshold = AgentRunTokenMeter.readOnlyThreshold
        }
        let seed = Seed(policyVersion: RunTokenBudgetSnapshot.currentPolicyVersion, definitionFingerprint: reference,
            modelSettingsFingerprint: settings.fingerprint, maxRunTokens: threshold, perRequestOutputLimit: settings.configuration.maxOutputTokens)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(fingerprint: fingerprint(String(decoding: try encoder.encode(seed), as: UTF8.self)), maxRunTokens: threshold,
            perRequestOutputLimit: settings.configuration.maxOutputTokens)
    }
    func agentTokenPauseNotice(_ error: AgentRunTokenError) -> LocalizedNotice {
        switch error {
        case .thresholdReached: noticeKey("Agent paused at the reported token threshold. No further tool or model request was dispatched.")
        case .usageUnavailable: noticeKey("Agent paused because reported usage could not be verified. No further tool or model request was dispatched.")
        case .invalidThreshold: noticeKey("Enter a valid positive run token threshold.")
        }
    }
    func finalizeRunTokenBudget(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), let current = tasks[index].runTokenBudget else { return }
        var known = current.knownTokens
        if let summary = tasks[index].aiUsageSummary, summary.reportedInputTokens != nil || summary.reportedOutputTokens != nil {
            let (total, overflow) = (summary.reportedInputTokens ?? 0).addingReportingOverflow(summary.reportedOutputTokens ?? 0)
            if !overflow { known = known.map { max($0, total) } ?? total }
        }
        var status: RunTokenBudgetSnapshot.Status = current.status == .awaitingUsage || known == nil || tasks[index].aiUsageSummary?.state != .reported ? .usageUnavailable : current.status
        if status == .verified, let known, known >= current.maximumTokens { status = .thresholdReached }
        tasks[index].runTokenBudget = .init(maximumTokens: current.maximumTokens, knownTokens: known, completedTurns: current.completedTurns, status: status)
    }
    func approvalMatchesFrozenRun(_ proposal: AgentToolApproval) -> Bool {
        guard let task = tasks.first(where: { $0.id == proposal.runID }) else { return false }
        return task.agentRunContractFingerprint == proposal.runContractFingerprint && task.runTokenBudget?.maximumTokens == proposal.maxRunTokens
    }
}
