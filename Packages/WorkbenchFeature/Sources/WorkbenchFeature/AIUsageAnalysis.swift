import Foundation
import AICore

struct AIUsageAnalysisReport: Sendable {
    let revision: UInt64
    let from: Date
    let to: Date
    let capturedAt: Date
    var scannedEntries = 0
    var readBytes = 0
    var readProblems = 0
    var invalidRecords = 0
    var duplicateAttempts = 0
    var incompleteWorkflows = 0
    var leafRecords = 0
    var calls = 0
    var unpricedCalls = 0
    var incompleteCalls = 0
    var legacyRecords = 0
    var inputTokens: Int?
    var outputTokens: Int?
    var legacyInputTokens: Int?
    var legacyOutputTokens: Int?
    var amounts: [AICurrencyAmount] = []
    var hasCoverageGaps: Bool {
        readProblems > 0 || invalidRecords > 0 || duplicateAttempts > 0 || incompleteWorkflows > 0 ||
        unpricedCalls > 0 || incompleteCalls > 0 || legacyRecords > 0
    }
}

/// 逐叶折叠，整个历史不拼成只允许128 calls的单次运行；仅保留有界去重身份与数值。
struct AIUsageAnalysisAccumulator {
    private struct Header: Decodable {
        let runID: UUID
        let recordedAt: Date
        let kind: String?
        let formatVersion: Int?
        let parentRunID: UUID?
        let workflowStepID: UUID?
    }
    private struct SeenCall {
        let fingerprint: String; var currencies: Set<String>
        var relevant: Bool; var duplicates = 0; var conflicted = false
        let cost: AICostSummary?
    }
    private struct Family { let index: WorkflowUsageIndex; var relevant: Bool }
    private struct LeafIdentity { let parent: UUID?; let step: UUID?; let relevant: Bool }
    private(set) var report: AIUsageAnalysisReport
    private var seenRecords: Set<UUID> = []
    private var seenCalls: [UUID: SeenCall] = [:]
    private var leaves: [UUID: LeafIdentity] = [:]
    private var families: [UUID: Family] = [:]
    private var relevantParents: Set<UUID> = []
    private var totals: [String: Decimal] = [:]
    private var invalidCurrencies: Set<String> = []
    private var inputOverflow = false, outputOverflow = false, legacyInputOverflow = false, legacyOutputOverflow = false
    static let maximumCalls = 32_768
    static let maximumFamilyLinks = 32_768
    private var familyLinks = 0

    init(from: Date, to: Date, revision: UInt64, now: Date = Date()) {
        report = .init(revision: revision, from: from, to: to, capturedAt: now)
    }
    mutating func problem() { report.readProblems += 1 }
    mutating func failedRead(bytes: Int) { report.readBytes += bytes; problem() }
    mutating func entry() { report.scannedEntries += 1 }
    mutating func consume(_ data: Data, id: UUID) {
        report.readBytes += data.count
        guard seenRecords.count < 5_000 else { report.readProblems += 1; return }
        guard data.count <= 65_536, seenRecords.insert(id).inserted,
              let header = try? JSONDecoder().decode(Header.self, from: data), header.runID == id,
              header.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              header.formatVersion == nil || (1...2).contains(header.formatVersion!) else { report.invalidRecords += 1; return }
        if header.kind == "workflowIndex" {
            guard let index = try? JSONDecoder().decode(WorkflowUsageIndex.self, from: data), index.isValid,
                  index.children.count <= Self.maximumFamilyLinks - familyLinks else { report.invalidRecords += 1; return }
            familyLinks += index.children.count
            families[id] = .init(index: index, relevant: contains(index.recordedAt))
            return
        }
        guard header.kind == nil, (header.parentRunID == nil) == (header.workflowStepID == nil) else { report.invalidRecords += 1; return }
        if let recorded = AIUsageLedgerReader.recordedCalls(data: data, runID: id) {
            var relevant = contains(header.recordedAt) && (recorded.overflowed || recorded.incomplete)
            for call in recorded.calls {
                let inRange = contains(call.startedAt)
                relevant = relevant || inRange
                // 窗外副本仍核验身份，不能通过修改startedAt绕过冲突检测。
                consume(call, relevant: inRange)
            }
            leaves[id] = .init(parent: header.parentRunID, step: header.workflowStepID, relevant: relevant)
            if relevant {
                if let parent = header.parentRunID { relevantParents.insert(parent) }
                report.leafRecords += 1
                if recorded.overflowed || recorded.incomplete { report.incompleteCalls += 1 }
            }
        } else if let legacy = AIUsageLedgerReader.legacySummary(data: data, runID: id) {
            guard contains(header.recordedAt) else { return }
            report.legacyRecords += 1
            Self.add(legacy.reportedInputTokens, to: &report.legacyInputTokens, overflow: &legacyInputOverflow)
            Self.add(legacy.reportedOutputTokens, to: &report.legacyOutputTokens, overflow: &legacyOutputOverflow)
        } else { report.invalidRecords += 1 }
    }
    private mutating func consume(_ call: AIRecordedCall, relevant: Bool) {
        guard let fingerprint = SavedItemIdentity.fingerprint(call) else { report.invalidRecords += 1; return }
        let currency = call.rate?.rate.currency
        if var old = seenCalls[call.attemptID] {
            if let currency { old.currencies.insert(currency) }
            old.relevant = old.relevant || relevant
            old.duplicates += 1
            old.conflicted = old.conflicted || old.fingerprint != fingerprint
            seenCalls[call.attemptID] = old
            if old.conflicted && old.relevant {
                for key in old.currencies { invalidCurrencies.insert(key); totals[key] = nil }
                inputOverflow = true; outputOverflow = true; report.inputTokens = nil; report.outputTokens = nil
            }
            return
        }
        guard seenCalls.count < Self.maximumCalls else { report.readProblems += 1; return }
        let cost = relevant ? AICostSummary.estimate(.init(calls: [call])) : nil
        seenCalls[call.attemptID] = .init(fingerprint: fingerprint, currencies: Set([currency].compactMap { $0 }), relevant: relevant, cost: cost)
        guard relevant else { return }
        Self.add(call.usage?.inputTokens, to: &report.inputTokens, overflow: &inputOverflow)
        Self.add(call.usage?.outputTokens, to: &report.outputTokens, overflow: &outputOverflow)
        for value in cost?.amounts ?? [] {
            guard !invalidCurrencies.contains(value.currency), let amount = Decimal(string: value.amount, locale: Locale(identifier: "en_US_POSIX")) else { continue }
            if let previous = totals[value.currency] {
                guard let sum = AIRateArithmetic.sum(previous, amount) else {
                    totals[value.currency] = nil; invalidCurrencies.insert(value.currency); report.invalidRecords += 1; continue
                }
                totals[value.currency] = sum
            } else { totals[value.currency] = amount }
        }
    }
    func finish() -> AIUsageAnalysisReport {
        var result = report
        // 派生计数按any-relevant身份统一生成，不依赖目录枚举顺序；冲突只贡献一条未知请求。
        for call in seenCalls.values where call.relevant {
            result.calls += 1; result.duplicateAttempts += call.duplicates
            if call.conflicted { result.incompleteCalls += 1; result.invalidRecords += 1 }
            else if let cost = call.cost {
                result.unpricedCalls += cost.unpricedCalls; result.incompleteCalls += cost.incompleteCalls; result.invalidRecords += cost.invalidCalls
            }
        }
        var incompleteParents: Set<UUID> = []
        for (parent, family) in families {
            guard family.relevant || relevantParents.contains(parent) else { continue }
            let incomplete = family.index.hasIncompleteRecords || family.index.children.contains { link in
                guard let child = leaves[link.childRunID] else { return true }
                return child.parent != parent || child.step != link.workflowStepID
            }
            if incomplete { incompleteParents.insert(parent) }
        }
        for (childID, leaf) in leaves where leaf.relevant {
            guard let parent = leaf.parent else { continue }
            guard let family = families[parent], family.index.children.contains(where: { $0.childRunID == childID && $0.workflowStepID == leaf.step }) else {
                incompleteParents.insert(parent); continue
            }
        }
        result.incompleteWorkflows = incompleteParents.count
        result.amounts = totals.keys.sorted().compactMap { currency in
            guard !invalidCurrencies.contains(currency), let value = totals[currency] else { return nil }
            return AICurrencyAmount(currency: currency, amount: AIRateArithmetic.string(value))
        }
        if inputOverflow || outputOverflow || legacyInputOverflow || legacyOutputOverflow { result.readProblems += 1 }
        return result
    }
    private func contains(_ date: Date) -> Bool { date >= report.from && date < report.to }
    private static func add(_ value: Int?, to total: inout Int?, overflow: inout Bool) {
        guard let value, !overflow, value >= 0 else { return }
        let result = (total ?? 0).addingReportingOverflow(value)
        if result.overflow { total = nil; overflow = true } else { total = result.partialValue }
    }
}

extension WorkbenchModel {
    func invalidateUsageAnalysis() {
        usageAnalysisRequestID = UUID(); usageAnalysisReport = nil; usageAnalysisLoading = false
        usageAnalysisRefreshToken = UUID()
    }
    func refreshAIUsageAnalysis(days: Int, reader: (@Sendable (Date, Date) async throws -> AIUsageAnalysisReport)? = nil) async {
        guard !isShuttingDown, !isClearingUsage, !Task.isCancelled, [7, 30, 90].contains(days) else { return }
        let request = UUID(), generation = usageHistoryGeneration, metadata = usageMetadataStore
        usageAnalysisRequestID = request; usageAnalysisReport = nil; usageAnalysisLoading = true
        defer { if usageAnalysisRequestID == request { usageAnalysisLoading = false } }
        let to = Date(), from = to.addingTimeInterval(-Double(days) * 86_400)
        for _ in 0..<3 {
            guard !Task.isCancelled else { return }
            let report: AIUsageAnalysisReport
            do { report = if let reader { try await reader(from, to) } else { try await metadata.readAnalysis(from: from, to: to) } }
            catch { return }
            guard !isShuttingDown, !isClearingUsage, usageHistoryGeneration == generation, usageAnalysisRequestID == request, !Task.isCancelled else { return }
            guard metadata.revisionFence.current == report.revision else { continue }
            usageAnalysisReport = report; return
        }
    }
}
