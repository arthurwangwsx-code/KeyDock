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
    static func summary(at url: URL, runID: UUID, interrupted: Bool) async -> AIUsageSummary {
        await Task.detached(priority: .utility) { () -> AIUsageSummary in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { return .unknown }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                guard let bytes = try file.read(upToCount: 1_048_577), bytes.count <= 1_048_576 else { return .unknown }
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: bytes)
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
        }.value
    }
}

extension WorkbenchModel {
    func publishAIUsage(_ id: UUID, facts: AIUsageFacts) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].aiUsageSummary = facts.summary
    }
    func loadRestoredAIUsage(_ id: UUID, interrupted: Bool) {
        let url = directory.appendingPathComponent("usage/" + id.uuidString + ".json")
        Task { [weak self] in
            let summary = await AIUsageLedgerReader.summary(at: url, runID: id, interrupted: interrupted)
            guard let self, !isShuttingDown, let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].restoredFromReceipt else { return }
            tasks[index].aiUsageSummary = summary
        }
    }
}
