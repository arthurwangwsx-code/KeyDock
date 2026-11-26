import Foundation
import AICore

/// 仅描述提供商已报告的数值；缺失保持nil，不能按零相加或据此计算费用。
public struct AIUsageSummary: Equatable, Sendable {
    public enum State: Equatable, Sendable { case pending, reported, partial, unknown, notRequested }
    public let state: State
    public let reportedInputTokens: Int?
    public let reportedOutputTokens: Int?
    public var cost = AICostSummary.unknown
    public static let pending = AIUsageSummary(state: .pending, reportedInputTokens: nil, reportedOutputTokens: nil)
    public static let unknown = AIUsageSummary(state: .unknown, reportedInputTokens: nil, reportedOutputTokens: nil)
    public static let notRequested = AIUsageSummary(state: .notRequested, reportedInputTokens: nil, reportedOutputTokens: nil)
    var stateTitle: String {
        switch state {
        case .pending: L("Usage pending")
        case .reported: L("Usage reported")
        case .partial: L("Usage partly reported")
        case .unknown: L("Usage unknown")
        case .notRequested: L("No direct model requests")
        }
    }
    var inputText: String { reportedInputTokens.map(String.init) ?? L("Unknown") }
    var outputText: String { reportedOutputTokens.map(String.init) ?? L("Unknown") }
    var costText: String {
        if state == .notRequested { return L("No direct model request was made. External tools may have their own charges.") }
        guard !cost.amounts.isEmpty else {
            if state == .pending { return L("Cost pending") }
            return cost.noHistoricalSnapshot ? L("Cost unknown (no historical rate snapshot)") : L("Cost unknown (missing rate or reported usage)")
        }
        let amounts = cost.amounts.map { $0.currency + " " + $0.amount }.joined(separator: " · ")
        return (cost.isComplete ? L("Estimated cost at custom rates") : L("Estimated reported portion; remainder unknown")) + ": " + amounts
    }
}

/// ledger与界面共用同一份事实。去重/累计/拒绝delta仍由AICore accumulator负责。
struct AIUsageFacts: Sendable {
    let observations: [AIUsage]
    let unknownAttempts: Set<UUID>
    let hasUnknownUsage: Bool
    let outcome: String
    private let input: Int?
    private let output: Int?
    private let recordedUsage: AIRecordedUsage?
    static func recorded(_ value: AIRecordedUsage, outcome: String, inheritedUnknown: Bool = false) -> Self {
        var accumulator = AIUsageAccumulator()
        for call in value.calls {
            if let usage = call.usage { do { try accumulator.observe(usage) } catch { accumulator.markUnknown(attemptID: call.attemptID) } }
            if call.hasUnknownUsage || call.outcome != .succeeded || call.finishedAt == nil { accumulator.markUnknown(attemptID: call.attemptID) }
        }
        return .init(accumulator: accumulator, outcome: outcome, inheritedUnknown: inheritedUnknown, recordedUsage: value)
    }

    init(accumulator: AIUsageAccumulator, outcome: String, inheritedUnknown: Bool = false, recordedUsage: AIRecordedUsage? = nil) {
        observations = accumulator.observations; unknownAttempts = accumulator.unknownAttempts
        self.outcome = outcome
        self.recordedUsage = recordedUsage
        let input = Self.knownTotal(observations.map(\.inputTokens))
        let output = Self.knownTotal(observations.map(\.outputTokens))
        self.input = input.value; self.output = output.value
        let requestUnknown = recordedUsage.map { $0.overflowed || $0.incomplete || $0.calls.contains { $0.hasUnknownUsage || $0.outcome != .succeeded || $0.finishedAt == nil } } ?? (outcome != "succeeded")
        hasUnknownUsage = inheritedUnknown || requestUnknown || accumulator.hasUnknownUsage || observations.isEmpty || input.overflow || output.overflow
    }
    var summary: AIUsageSummary {
        let state: AIUsageSummary.State
        if outcome == "running" { state = .pending }
        else if input == nil && output == nil { state = .unknown }
        else { state = hasUnknownUsage ? .partial : .reported }
        return AIUsageSummary(state: state, reportedInputTokens: input, reportedOutputTokens: output, cost: .estimate(recordedUsage))
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
        let recordedUsage: AIRecordedUsage?
        let parentRunID: UUID?
        let workflowStepID: UUID?
        let hasRecordedUsage: Bool
        private enum CodingKeys: String, CodingKey { case runID, observations, unknownAttempts, hasUnknownUsage, outcome, recordedUsage, parentRunID, workflowStepID }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runID = try c.decode(UUID.self, forKey: .runID); observations = try c.decode([AIUsage].self, forKey: .observations)
            unknownAttempts = try c.decode(Set<UUID>.self, forKey: .unknownAttempts)
            hasUnknownUsage = try c.decode(Bool.self, forKey: .hasUnknownUsage); outcome = try c.decode(String.self, forKey: .outcome)
            recordedUsage = try? c.decodeIfPresent(AIRecordedUsage.self, forKey: .recordedUsage)
            hasRecordedUsage = c.contains(.recordedUsage) && ((try? c.decodeNil(forKey: .recordedUsage)) == false)
            parentRunID = try c.decodeIfPresent(UUID.self, forKey: .parentRunID)
            workflowStepID = try c.decodeIfPresent(UUID.self, forKey: .workflowStepID)
        }
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
            let recorded = snapshot.hasRecordedUsage ? (recordedCalls(data: data, runID: runID) ?? .init(incomplete: true)) : nil
            return AIUsageFacts(accumulator: accumulator, outcome: outcome,
                inheritedUnknown: interrupted || snapshot.hasUnknownUsage, recordedUsage: recorded).summary
        } catch { return .unknown }
    }

    /// 费率与事实轴分开；新逐调用字段必须与原observations准确对应，不能展示互相矛盾的金额与token。
    static func recordedCalls(data: Data, runID: UUID, parentRunID: UUID? = nil, stepID: UUID? = nil) -> AIRecordedUsage? {
        guard data.count <= 65_536, let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.runID == runID,
              let recorded = snapshot.recordedUsage, recorded.calls.count <= 128, snapshot.observations.count <= 128,
              parentRunID == nil || (snapshot.parentRunID == parentRunID && snapshot.workflowStepID == stepID && stepID != nil) else { return nil }
        var expected: [UUID: AIUsage] = [:], ids: Set<UUID> = []
        for call in recorded.calls {
            guard ids.insert(call.attemptID).inserted, AIServiceIdentity.isFingerprint(call.endpointFingerprint),
                  !call.model.isEmpty, call.model.utf8.count <= 256, call.startedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
            if let usage = call.usage {
                guard usage.attemptID == call.attemptID, usage.counting == .cumulative, (usage.inputTokens ?? 0) >= 0, (usage.outputTokens ?? 0) >= 0 else { return nil }
                expected[call.attemptID] = usage
            }
        }
        guard snapshot.unknownAttempts.isSubset(of: ids), expected.count == snapshot.observations.count else { return nil }
        for usage in snapshot.observations { guard expected.removeValue(forKey: usage.attemptID) == usage else { return nil } }
        return expected.isEmpty ? recorded : nil
    }
    static func legacySummary(data: Data, runID: UUID) -> AIUsageSummary? {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.runID == runID, !snapshot.hasRecordedUsage else { return nil }
        return summary(data: data, runID: runID, interrupted: false)
    }

}

extension WorkbenchModel {
    func publishAIUsage(_ id: UUID, facts: AIUsageFacts, metadataRevision: UInt64 = 0) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].aiUsageSummary = facts.summary
        usageSummaryGenerations[id] = usageHistoryGeneration
        usageSummaryRevisions[id] = metadataRevision
        invalidatedUsageRuns.remove(id)
    }
    @discardableResult func loadRestoredAIUsage(_ id: UUID, interrupted: Bool,
        reader: (@Sendable () async -> AIUsageMetadataReadResult)? = nil) -> Task<Void, Never> {
        let generation = historyGeneration, usageGeneration = usageHistoryGeneration
        let usageRead = captureUsageRestoreRead()
        let metadata = usageMetadataStore
        return Task { [weak self] in
            // 无关记录写入也会推进全局代次；有界重读保留有效历史，同时不放松清除/TTL围栏。
            for _ in 0..<3 {
                guard let self, canAcceptRestoredUsage(id, history: generation, usage: usageGeneration, usageRead: usageRead) else { return }
                let read = if let reader { await reader() } else { await metadata.read(id: id) }
                let summary = await Task.detached(priority: .utility) { AIUsageLedgerReader.summary(data: read.data, runID: id, interrupted: interrupted) }.value
                guard canAcceptRestoredUsage(id, history: generation, usage: usageGeneration, usageRead: usageRead) else { return }
                guard metadata.revisionFence.current == read.revision else { continue }
                applyRestoredAIUsage(summary, id: id, historyGeneration: generation, usageGeneration: usageGeneration, metadataRevision: read.revision, usageRead: usageRead)
                return
            }
        }
    }
    func canAcceptRestoredUsage(_ id: UUID, history: UInt64, usage: UInt64, usageRead: UsageRestoreReadTicket) -> Bool {
        acceptsUsageRestoreRead(usageRead) && historyGeneration == history && usageHistoryGeneration == usage && !invalidatedUsageRuns.contains(id) &&
        tasks.contains { $0.id == id && $0.restoredFromReceipt }
    }
    func applyRestoredAIUsage(_ summary: AIUsageSummary, id: UUID, historyGeneration: UInt64, usageGeneration: UInt64, metadataRevision: UInt64? = nil, usageRead: UsageRestoreReadTicket? = nil) {
        guard !isDesktopReview else { return }
        guard acceptsUsageRestoreRead(usageRead), self.historyGeneration == historyGeneration, usageHistoryGeneration == usageGeneration, !invalidatedUsageRuns.contains(id),
              metadataRevision == nil || metadataRevision == usageMetadataStore.revisionFence.current,
              let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].restoredFromReceipt else { return }
        tasks[index].aiUsageSummary = summary; usageSummaryGenerations[id] = usageGeneration; usageSummaryRevisions[id] = metadataRevision ?? 0
    }
}
