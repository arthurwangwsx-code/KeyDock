import Foundation
import Testing
import AICore
@testable import WorkbenchFeature

@Suite struct AIUsageAnalysisTests {
    private let now = Date()
    private var from: Date { now.addingTimeInterval(-7 * 86_400) }

    @Test func moreThanOneRunBudgetIsFoldedWithoutTruncatingOrCountingTheParent() throws {
        var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 9)
        let parent = UUID(), steps = (0..<129).map { _ in UUID() }, ids = (0..<129).map { _ in UUID() }
        // 一个工作流最多128步骤；这里由128步工作流和一个直接请求组成。
        for index in ids.indices {
            let call = try makeCall(at: now.addingTimeInterval(-60), currency: "USD")
            fold.consume(try leaf(ids[index], calls: [call], parent: index < 128 ? parent : nil, step: index < 128 ? steps[index] : nil), id: ids[index])
        }
        let links = (0..<128).map { WorkflowUsageLink(childRunID: ids[$0], workflowStepID: steps[$0]) }
        fold.consume(try index(parent, children: links), id: parent)
        let report = fold.finish()
        #expect(report.calls == 129 && report.leafRecords == 129 && report.incompleteWorkflows == 0)
        #expect(report.inputTokens == 1_548 && report.outputTokens == 645)
        #expect(report.amounts.first?.amount == "0.005676" && !report.hasCoverageGaps)
    }
    @Test func requestStartAndLegacyRecordDatesUseExclusiveUpperBound() throws {
        var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 0)
        for date in [from.addingTimeInterval(-1), from, now.addingTimeInterval(-1), now] {
            let id = UUID(); fold.consume(try leaf(id, calls: [makeCall(at: date)], recordedAt: now.addingTimeInterval(100)), id: id)
        }
        let included = UUID(), excluded = UUID()
        fold.consume(try legacy(included, recordedAt: from), id: included)
        fold.consume(try legacy(excluded, recordedAt: now), id: excluded)
        let report = fold.finish()
        #expect(report.calls == 2 && report.inputTokens == 24 && report.outputTokens == 10)
        #expect(report.legacyRecords == 1 && report.legacyInputTokens == 7 && report.legacyOutputTokens == 3)
        #expect(report.amounts.first?.amount == "0.000088")
    }
    @Test func missingPricesAndUsageDoNotBecomeZeroAndCurrenciesStaySeparate() throws {
        var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 0)
        let calls = [try makeCall(currency: "USD"), try makeCall(currency: "EUR"), try makeCall(currency: nil), try makeCall(input: nil, output: nil), try makeCall(input: 0, output: 0)]
        let id = UUID(); fold.consume(try leaf(id, calls: calls), id: id)
        let report = fold.finish()
        #expect(report.calls == 5 && report.unpricedCalls == 1 && report.incompleteCalls == 1)
        #expect(report.amounts.map(\.currency) == ["EUR", "USD"])
        #expect(report.amounts.map(\.amount) == ["0.000044", "0.000044"])
        #expect(report.inputTokens == 36 && report.outputTokens == 15 && report.hasCoverageGaps)
    }
    @Test func duplicateAttemptIsNeverChargedTwiceAndConflictsInvalidateAffectedTotals() throws {
        let call = try makeCall()
        var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 0)
        for _ in 0..<2 { let id = UUID(); fold.consume(try leaf(id, calls: [call]), id: id) }
        var report = fold.finish()
        #expect(report.calls == 1 && report.duplicateAttempts == 1 && report.amounts.first?.amount == "0.000044")
        var conflict = call; conflict.usage?.inputTokens = 99
        let id = UUID(); fold.consume(try leaf(id, calls: [conflict]), id: id)
        report = fold.finish()
        #expect(report.calls == 1 && report.amounts.isEmpty && report.inputTokens == nil && report.outputTokens == nil)
    }
    @Test func conflictingAttemptAcrossDateBoundaryCannotHideOutsideTheRange() throws {
        let inside = try makeCall()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(inside)) as? [String: Any])
        object["startedAt"] = from.addingTimeInterval(-60).timeIntervalSinceReferenceDate
        let outside = try JSONDecoder().decode(AIRecordedCall.self, from: JSONSerialization.data(withJSONObject: object))
        for ordered in [[inside, outside], [outside, inside]] {
            var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 0)
            for call in ordered { let id = UUID(); fold.consume(try leaf(id, calls: [call]), id: id) }
            let report = fold.finish()
            #expect(report.duplicateAttempts == 1 && report.hasCoverageGaps && report.amounts.isEmpty)
            #expect(report.inputTokens == nil && report.outputTokens == nil)
            #expect(report.calls == 1 && report.incompleteCalls == 1 && report.unpricedCalls == 0 && report.invalidRecords == 1)
        }
    }
    @Test func missingAndUnlinkedWorkflowRecordsRemainVisibleCoverageGaps() throws {
        let parent = UUID(), missing = UUID(), orphanParent = UUID(), leafID = UUID()
        var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 0)
        fold.consume(try index(parent, children: [.init(childRunID: missing, workflowStepID: UUID())], incomplete: true), id: parent)
        fold.consume(try leaf(leafID, calls: [makeCall()], parent: orphanParent, step: UUID()), id: leafID)
        let report = fold.finish()
        #expect(report.calls == 1 && report.incompleteWorkflows == 2 && report.hasCoverageGaps)
        #expect(report.amounts.first?.amount == "0.000044")
    }
    @Test func parentMustListEveryRelevantLeafWithTheExactStepInEitherReadOrder() throws {
        let parent = UUID(), child = UUID(), step = UUID(), childData = try leaf(child, calls: [makeCall()], parent: parent, step: step)
        for links: [WorkflowUsageLink] in [[], [.init(childRunID: child, workflowStepID: UUID())]] {
            let parentData = try index(parent, children: links)
            for ordered in [[(parent, parentData), (child, childData)], [(child, childData), (parent, parentData)]] {
                var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 0)
                for (id, data) in ordered { fold.consume(data, id: id) }
                let report = fold.finish()
                #expect(report.calls == 1 && report.incompleteWorkflows == 1 && report.hasCoverageGaps)
                #expect(report.amounts.first?.amount == "0.000044")
            }
        }
    }
    @Test func malformedNewSnapshotCannotFallBackToLegacyOrEraseOtherRecords() throws {
        let good = UUID(), bad = UUID(), empty = UUID()
        var fold = AIUsageAnalysisAccumulator(from: from, to: now, revision: 0)
        fold.consume(try leaf(good, calls: [makeCall()]), id: good)
        var object = try #require(JSONSerialization.jsonObject(with: leaf(bad, calls: [makeCall()])) as? [String: Any])
        object["recordedUsage"] = ["calls": "corrupt"]
        fold.consume(try JSONSerialization.data(withJSONObject: object), id: bad)
        fold.consume(try leaf(empty, calls: [], incomplete: true), id: empty)
        let report = fold.finish()
        #expect(report.calls == 1 && report.invalidRecords == 1 && report.legacyRecords == 0 && report.incompleteCalls == 1)
        #expect(report.amounts.first?.amount == "0.000044")
    }
    @Test func actorReadIsBoundedAndDoesNotFollowLinksOrModifyRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Synthetic-Analysis-" + UUID().uuidString)
        let dir = root.appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json"), outsideID = UUID()
        let outsideData = try leaf(outsideID, calls: [makeCall()])
        try outsideData.write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(outsideID.uuidString + ".json"), withDestinationURL: outside)
        let good = UUID(), goodData = try leaf(good, calls: [makeCall()])
        try goodData.write(to: dir.appendingPathComponent(good.uuidString + ".json"))
        var policy = AIUsageRetentionPolicy(); policy.maximumTotalBytes = UInt64(goodData.count)
        let store = AIUsageMetadataStore(directory: dir, policy: policy)
        let report = try await store.readAnalysis(from: from, to: now)
        #expect(report.calls == 1 && report.readProblems == 1 && report.readBytes <= goodData.count)
        #expect(try Data(contentsOf: outside) == outsideData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
        let cleared = await store.clear()
        let after = try await store.readAnalysis(from: from, to: now)
        #expect(after.calls == 0 && after.amounts.isEmpty && after.revision == cleared.revision)
    }
    @Test func actorCountAndByteBudgetsYieldPartialCoverageRatherThanInventedZero() async throws {
        for byteLimited in [false, true] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Synthetic-Analysis-Budget-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var largest = 0
            for _ in 0..<3 {
                let id = UUID(), data = try leaf(id, calls: [makeCall()]); largest = max(largest, data.count)
                try data.write(to: dir.appendingPathComponent(id.uuidString + ".json"))
            }
            var policy = AIUsageRetentionPolicy(); policy.maximumCount = byteLimited ? 5_000 : 1
            policy.maximumTotalBytes = byteLimited ? UInt64(largest) : 16 * 1_024 * 1_024
            let report = try await AIUsageMetadataStore(directory: dir, policy: policy).readAnalysis(from: from, to: now)
            #expect(report.calls == 1 && report.readProblems == 1 && report.hasCoverageGaps)
            #expect(report.readBytes <= policy.maximumTotalBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 3)
        }
    }
    private func makeCall(at: Date? = nil, currency: String? = "USD", input: Int? = 12, output: Int? = 5) throws -> AIRecordedCall {
        let url = URL(string: "https://example.com/synthetic")!, model = "synthetic-model", date = at ?? now.addingTimeInterval(-60)
        let rate = currency.map { AIRateSnapshot(rate: .init(endpointFingerprint: AIServiceIdentity.fingerprint(url), model: model, currency: $0, inputPerMillion: "2", outputPerMillion: "4"), frozenAt: date) }
        let recorder = AIUsageRecorder(rate: rate), worker = try #require(recorder.beginWorker())
        let id = try #require(recorder.beginAttempt(worker: worker, configuration: .init(endpoint: url, model: model), at: date))
        recorder.observe(.init(inputTokens: input, outputTokens: output, attemptID: id))
        recorder.finishAttempt(id, outcome: .succeeded, at: date.addingTimeInterval(1)); recorder.endWorker(worker)
        return try #require(recorder.snapshot().calls.first)
    }
    private func leaf(_ id: UUID, calls: [AIRecordedCall], recordedAt: Date? = nil, parent: UUID? = nil, step: UUID? = nil, incomplete: Bool = false) throws -> Data {
        struct Record: Encodable {
            let formatVersion = 2; let runID: UUID; let recordedAt: Date
            let observations: [AIUsage]; let unknownAttempts: Set<UUID>; let hasUnknownUsage: Bool
            let outcome = "succeeded"; let recordedUsage: AIRecordedUsage
            let parentRunID: UUID?; let workflowStepID: UUID?
        }
        return try JSONEncoder().encode(Record(runID: id, recordedAt: recordedAt ?? now.addingTimeInterval(-10), observations: calls.compactMap(\.usage), unknownAttempts: [], hasUnknownUsage: incomplete, recordedUsage: .init(calls: calls, incomplete: incomplete), parentRunID: parent, workflowStepID: step))
    }
    private func legacy(_ id: UUID, recordedAt: Date) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: leaf(id, calls: [makeCall(input: 7, output: 3)], recordedAt: recordedAt)) as? [String: Any])
        object["recordedUsage"] = nil; object["formatVersion"] = nil
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func index(_ id: UUID, children: [WorkflowUsageLink], incomplete: Bool = false) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkflowUsageIndex(runID: id, children: children, hasIncompleteRecords: incomplete))) as? [String: Any])
        object["recordedAt"] = now.addingTimeInterval(-5).timeIntervalSinceReferenceDate
        return try JSONSerialization.data(withJSONObject: object)
    }
}
