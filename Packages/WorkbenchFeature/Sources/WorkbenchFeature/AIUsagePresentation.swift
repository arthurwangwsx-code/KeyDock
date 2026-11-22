import Foundation
import AICore

/// 仅描述提供商已报告的数值；缺失保持nil，不能按零相加或据此计算费用。
public struct AIUsageSummary: Equatable, Sendable {
    public enum State: Equatable, Sendable { case pending, reported, partial, unknown }
    public let state: State
    public let reportedInputTokens: Int?
    public let reportedOutputTokens: Int?
    public static let pending = AIUsageSummary(state: .pending, reportedInputTokens: nil, reportedOutputTokens: nil)
    public static let unknown = AIUsageSummary(state: .unknown, reportedInputTokens: nil, reportedOutputTokens: nil)
    var stateTitle: String {
        switch state {
        case .pending: L("Usage pending")
        case .reported: L("Usage reported")
        case .partial: L("Usage partly reported")
        case .unknown: L("Usage unknown")
        }
    }
    var inputText: String { reportedInputTokens.map(String.init) ?? L("Unknown") }
    var outputText: String { reportedOutputTokens.map(String.init) ?? L("Unknown") }
    var costText: String { L("Cost unknown (no rate configured)") }
}

/// ledger与界面共用同一份事实。去重/累计/拒绝delta仍由AICore accumulator负责。
struct AIUsageFacts: Sendable {
    let observations: [AIUsage]
    let unknownAttempts: Set<UUID>
    let hasUnknownUsage: Bool
    let outcome: String
    private let input: Int?
    private let output: Int?

    init(accumulator: AIUsageAccumulator, outcome: String, inheritedUnknown: Bool = false) {
        observations = accumulator.observations; unknownAttempts = accumulator.unknownAttempts
        self.outcome = outcome
        let input = Self.knownTotal(observations.map(\.inputTokens))
        let output = Self.knownTotal(observations.map(\.outputTokens))
        self.input = input.value; self.output = output.value
        hasUnknownUsage = inheritedUnknown || outcome != "succeeded" || accumulator.hasUnknownUsage || observations.isEmpty || input.overflow || output.overflow
    }
    var summary: AIUsageSummary {
        let state: AIUsageSummary.State
        if outcome == "running" { state = .pending }
        else if input == nil && output == nil { state = .unknown }
        else { state = hasUnknownUsage ? .partial : .reported }
        return AIUsageSummary(state: state, reportedInputTokens: input, reportedOutputTokens: output)
    }
    private static func knownTotal(_ values: [Int?]) -> (value: Int?, overflow: Bool) {
        var total: Int?
        for case let value? in values {
            let result = (total ?? 0).addingReportingOverflow(value)
            guard !result.overflow else { return (nil, true) }
            total = result.partialValue
        }
        return (total, false)
    }
}

/// 只读既有ledger的有界元数据；不读取配置、凭据或正文，损坏/缺失不冒充零消耗。
enum AIUsageLedgerReader {
    private struct Snapshot: Decodable {
        let runID: UUID
        let observations: [AIUsage]
        let unknownAttempts: Set<UUID>
        let hasUnknownUsage: Bool
        let outcome: String
    }
    /// 生产恢复从metadata actor取得有界、无符号链接的data，再与实时结果共用同一份事实解析。
    static func summary(data: Data?, runID: UUID, interrupted: Bool) -> AIUsageSummary {
        guard let data, data.count <= 65_536 else { return .unknown }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.runID == runID, snapshot.observations.count <= 128 else { return .unknown }
            var accumulator = AIUsageAccumulator()
            for observation in snapshot.observations {
                do { try accumulator.observe(observation) }
                catch { accumulator.markUnknown(attemptID: observation.attemptID) }
            }
            for id in snapshot.unknownAttempts { accumulator.markUnknown(attemptID: id) }
            let outcome = snapshot.outcome == "running" ? "interrupted" : snapshot.outcome
            return AIUsageFacts(accumulator: accumulator, outcome: outcome,
                inheritedUnknown: interrupted || snapshot.hasUnknownUsage).summary
        } catch { return .unknown }
    }

}

extension WorkbenchModel {
    func publishAIUsage(_ id: UUID, facts: AIUsageFacts) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].aiUsageSummary = facts.summary
        usageSummaryGenerations[id] = usageHistoryGeneration
        invalidatedUsageRuns.remove(id)
    }
    func loadRestoredAIUsage(_ id: UUID, interrupted: Bool) {
        let generation = historyGeneration, usageGeneration = usageHistoryGeneration
        let metadata = usageMetadataStore
        Task { [weak self] in
            let read = await metadata.read(id: id)
            let summary = await Task.detached(priority: .utility) { AIUsageLedgerReader.summary(data: read.data, runID: id, interrupted: interrupted) }.value
            self?.applyRestoredAIUsage(summary, id: id, historyGeneration: generation, usageGeneration: usageGeneration)
        }
    }
    func applyRestoredAIUsage(_ summary: AIUsageSummary, id: UUID, historyGeneration: UInt64, usageGeneration: UInt64) {
        guard !isShuttingDown, self.historyGeneration == historyGeneration, usageHistoryGeneration == usageGeneration, !invalidatedUsageRuns.contains(id),
              let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].restoredFromReceipt else { return }
        tasks[index].aiUsageSummary = summary; usageSummaryGenerations[id] = usageGeneration
    }
}
