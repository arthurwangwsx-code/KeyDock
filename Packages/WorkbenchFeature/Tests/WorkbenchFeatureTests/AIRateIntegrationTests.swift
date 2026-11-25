import Foundation
import Testing
import AICore
import AutomationCore
import MacAdapters
@testable import WorkbenchFeature

private actor UsageRestoreReadProbe {
    let metadata: AIUsageMetadataStore
    let id: UUID
    let gate: SourceRemovalGate
    private(set) var reads = 0
    init(metadata: AIUsageMetadataStore, id: UUID, gate: SourceRemovalGate) { self.metadata = metadata; self.id = id; self.gate = gate }
    func direct() async -> AIUsageMetadataReadResult {
        reads += 1; let first = reads == 1
        let captured = await metadata.read(id: id)
        if first { await gate.wait() }
        return captured
    }
    func family() async throws -> WorkflowUsageRead {
        reads += 1; let first = reads == 1
        let captured = try await metadata.readWorkflowUsage(id: id)
        if first { await gate.wait() }
        return captured
    }
    func analysis(from: Date, to: Date) async throws -> AIUsageAnalysisReport {
        reads += 1; let first = reads == 1
        let captured = try await metadata.readAnalysis(from: from, to: to)
        if first { await gate.wait() }
        return captured
    }
}

@Suite(.serialized) @MainActor struct AIRateIntegrationTests {
    @Test func completedRequestKeepsFrozenRateAcrossEditAndHistoryRestore() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store
            let original = try addRate(store, currency: "USD", input: "2", output: "4")
            let draft = store.createDraft(input: "Synthetic private priced input")
            let id = try #require(store.runAI(action: fixture.action, draft: draft))
            var changed = original; changed.inputPerMillion = "999"
            #expect(store.saveAIRate(changed, replacing: original))
            try await fixture.drain(id)
            let live = try #require(store.tasks.first { $0.id == id }?.aiUsageSummary)
            #expect(live.cost.isComplete && live.cost.amounts.first?.amount == "0.000044")
            #expect(live.reportedInputTokens == 12 && live.reportedOutputTokens == 5)
            let data = try fixture.usageData(id), text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains(draft.input) && !text.contains(store.configuration.endpoint))
            let recorded = try #require(AIUsageLedgerReader.recordedCalls(data: data, runID: id))
            #expect(recorded.calls.count == 1 && recorded.calls[0].rate?.rate.inputPerMillion == "2")
            #expect(AIUsageLedgerReader.summary(data: data, runID: id, interrupted: false) == live)
            let restarted = try WorkbenchModel(dataDirectory: fixture.directory, allowContextCapture: false, applicationCatalog: ApplicationCatalog(roots: []))
            defer { restarted.shutdown() }
            try await storeEventually { restarted.tasks.first { $0.id == id }?.aiUsageSummary?.cost.amounts.isEmpty == false }
            #expect(restarted.tasks.first { $0.id == id }?.aiUsageSummary == live)
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 1)
        }
    }
    @Test func productParsingFailureDoesNotUndoSuccessfulModelUsage() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            _ = try addRate(fixture.store, currency: "USD", input: "2", output: "4")
            let draft = fixture.store.createDraft(input: "Synthetic invalid proposal response")
            fixture.store.generateCommandProposal(draft: draft)
            let id = try #require(fixture.store.proposalRequests[draft.id])
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.status == .failed && task.aiUsageSummary?.state == .reported)
            #expect(task.aiUsageSummary?.cost.isComplete == true && task.aiUsageSummary?.cost.amounts.first?.amount == "0.000044")
            let recorded = try #require(AIUsageLedgerReader.recordedCalls(data: fixture.usageData(id), runID: id))
            #expect(recorded.calls.first?.outcome == .succeeded)
            try fixture.assertNoCommandEffects()
        }
    }
    @Test func readOnlyAgentCountsTwoActualRequestsOnceEach() async throws {
        try await withStoreHTTPFixture(path: "agent") { fixture in
            _ = try addRate(fixture.store, currency: "USD", input: "2", output: "4")
            let draft = fixture.store.createDraft(input: "Synthetic priced time question")
            fixture.store.runReadOnlyAgent(draft: draft)
            let id = try #require(fixture.store.tasks.first?.id)
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.aiUsageSummary?.reportedInputTokens == 30 && task.aiUsageSummary?.reportedOutputTokens == 10)
            #expect(task.aiUsageSummary?.cost.callCount == 2 && task.aiUsageSummary?.cost.amounts.first?.amount == "0.0001")
            #expect(task.aiUsageSummary?.cost.isComplete == true)
            let recorded = try #require(AIUsageLedgerReader.recordedCalls(data: fixture.usageData(id), runID: id))
            #expect(Set(recorded.calls.map(\.attemptID)).count == 2)
        }
    }
    @Test func workflowParentIsAnIndexAndRestoresMultipleModelsAndCurrencies() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store
            var second = AIActionPreset(name: "Synthetic second model", prompt: "Use only synthetic input.")
            second.modelOverride = "synthetic-other-model"; store.configuration.aiActions.append(second)
            _ = try addRate(store, currency: "USD", input: "2", output: "4")
            _ = try addRate(store, model: second.modelOverride, currency: "EUR", input: "1", output: "1")
            let flow = WorkflowDefinition(name: "Synthetic priced workflow", steps: [.init(operation: .aiAction(fixture.action.id)), .init(operation: .aiAction(second.id), input: .previousOutput)])
            let id = try #require(store.runWorkflow(flow, input: "Synthetic workflow input"))
            try await fixture.drain(id)
            let live = try #require(store.tasks.first { $0.id == id }?.aiUsageSummary)
            #expect(live.reportedInputTokens == 24 && live.reportedOutputTokens == 10)
            #expect(live.cost.isComplete && live.cost.callCount == 2)
            #expect(live.cost.amounts.map(\.currency) == ["EUR", "USD"])
            #expect(live.cost.amounts.map(\.amount) == ["0.000017", "0.000044"])
            #expect(store.workflowAIUsage[id] == nil)
            let data = try fixture.usageData(id), index = try JSONDecoder().decode(WorkflowUsageIndex.self, from: data)
            #expect(index.isValid && index.children.count == 2)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["recordedUsage"] == nil && object["observations"] == nil)
            let family = try await store.usageMetadataStore.readWorkflowUsage(id: id)
            #expect(WorkflowUsageAggregation.summary(family.recorded, running: false) == live)
            for rate in store.configuration.aiRates { #expect(store.removeAIRate(rate)) }
            let restarted = try WorkbenchModel(dataDirectory: fixture.directory, allowContextCapture: false, applicationCatalog: ApplicationCatalog(roots: []))
            defer { restarted.shutdown() }
            try await storeEventually { restarted.tasks.first { $0.id == id }?.aiUsageSummary?.cost.amounts.count == 2 }
            #expect(restarted.tasks.first { $0.id == id }?.aiUsageSummary == live)
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 2)
        }
    }
    @Test func clearingBetweenWorkflowStepsNeverRevivesDeletedLeafCounts() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store, original = try addRate(fixture.store, currency: "USD", input: "2", output: "4")
            let flow = WorkflowDefinition(name: "Synthetic clear between model calls", steps: [.init(operation: .aiAction(fixture.action.id)), .init(operation: .manualInput, input: .previousOutput), .init(operation: .aiAction(fixture.action.id), input: .previousOutput)])
            let id = try #require(store.runWorkflow(flow, input: "Synthetic input"))
            try await storeEventually { store.pendingWorkflowInputs.contains { $0.runID == id } }
            let child = try #require(store.workflowAIUsage[id]?.children.keys.first)
            #expect(store.workflowAIUsage[id]?.children.count == 1)
            var changed = original; changed.inputPerMillion = "999"
            #expect(store.saveAIRate(changed, replacing: original))
            let newer = try #require(store.configuration.aiRates.first)
            #expect(store.removeAIRate(newer))
            await store.clearAIUsageHistory()
            #expect(store.workflowAIUsage[id]?.children.isEmpty == true && store.workflowAIUsage[id]?.incomplete == true)
            #expect(store.tasks.first { $0.id == id }?.aiUsageSummary == .unknown)
            let input = try #require(store.pendingWorkflowInputs.first { $0.runID == id })
            store.resolveWorkflowInput(input.id, value: "Synthetic continued input")
            try await fixture.drain(id)
            let live = try #require(store.tasks.first { $0.id == id }?.aiUsageSummary)
            #expect(live.reportedInputTokens == 12 && live.reportedOutputTokens == 5)
            #expect(!live.cost.isComplete && live.cost.amounts.first?.amount == "0.000044")
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("usage/" + child.uuidString + ".json").path))
            let index = try JSONDecoder().decode(WorkflowUsageIndex.self, from: fixture.usageData(id))
            #expect(index.children.count == 1 && index.children.first?.childRunID != child && index.hasIncompleteRecords)
            let family = try await store.usageMetadataStore.readWorkflowUsage(id: id)
            #expect(WorkflowUsageAggregation.summary(family.recorded, running: false) == live)
        }
    }
    @Test func emptyCompletedIndexIsDistinctFromOldMissingOrInvalidIndex() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let id = try #require(fixture.store.runWorkflow(.init(name: "Synthetic local transform", steps: [.init(operation: .transform(.trim))]), input: " Synthetic "))
            try await fixture.drain(id)
            #expect(try fixture.task(id).aiUsageSummary == .notRequested)
            let complete = try await fixture.store.usageMetadataStore.readWorkflowUsage(id: id)
            #expect(WorkflowUsageAggregation.summary(complete.recorded, running: false) == .notRequested)
            let missing = try await fixture.store.usageMetadataStore.readWorkflowUsage(id: UUID())
            #expect(WorkflowUsageAggregation.summary(missing.recorded, running: false).state == .unknown)
            let invalid = WorkflowUsageIndex(runID: id, children: [.init(childRunID: id, workflowStepID: UUID())], hasIncompleteRecords: false)
            #expect(!invalid.isValid)
            _ = await fixture.store.usageMetadataStore.save(id: id, data: try JSONEncoder().encode(invalid))
            let circular = try await fixture.store.usageMetadataStore.readWorkflowUsage(id: id)
            #expect(WorkflowUsageAggregation.summary(circular.recorded, running: false).state == .unknown)
        }
    }
    @Test func lateClearSnapshotCannotInvalidateANewerCompletedWorkflowFamily() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store
            _ = try addRate(store, currency: "USD", input: "2", output: "4")
            let oldClear = await store.usageMetadataStore.clear()
            let flow = WorkflowDefinition(name: "Synthetic new family after old clear", steps: [.init(operation: .aiAction(fixture.action.id))])
            let id = try #require(store.runWorkflow(flow, input: "Synthetic input"))
            try await fixture.drain(id)
            let before = try #require(store.tasks.first { $0.id == id }?.aiUsageSummary)
            #expect(before.cost.isComplete && before.cost.amounts.first?.amount == "0.000044")
            #expect(store.workflowUsageDependencies[id]?.values.allSatisfy { $0 > oldClear.revision } == true)
            store.invalidateWorkflowUsage(oldClear.removedIDs, revision: oldClear.revision, remaining: oldClear.remainingIDs)
            #expect(store.tasks.first { $0.id == id }?.aiUsageSummary == before)
        }
    }
    @Test func familyRejectsWrongParentOrStepWithoutFollowingOtherIndices() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let flow = WorkflowDefinition(name: "Synthetic family validation", steps: [.init(operation: .aiAction(fixture.action.id))])
            let id = try #require(fixture.store.runWorkflow(flow, input: "Synthetic input"))
            try await fixture.drain(id)
            let index = try JSONDecoder().decode(WorkflowUsageIndex.self, from: fixture.usageData(id)), child = try #require(index.children.first)
            let original = try fixture.usageData(child.childRunID)
            for key in ["parentRunID", "workflowStepID"] {
                var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); object[key] = UUID().uuidString
                _ = await fixture.store.usageMetadataStore.save(id: child.childRunID, data: try JSONSerialization.data(withJSONObject: object))
                let result = try await fixture.store.usageMetadataStore.readWorkflowUsage(id: id)
                #expect(result.recorded.calls.isEmpty && result.recorded.incomplete)
            }
            let nested = WorkflowUsageIndex(runID: child.childRunID, children: [.init(childRunID: id, workflowStepID: UUID())], hasIncompleteRecords: false)
            _ = await fixture.store.usageMetadataStore.save(id: child.childRunID, data: try JSONEncoder().encode(nested))
            let result = try await fixture.store.usageMetadataStore.readWorkflowUsage(id: id)
            #expect(result.recorded.calls.isEmpty && result.recorded.incomplete)
        }
    }
    @Test func unrelatedWriteRereadsDirectUsageInsteadOfLeavingValidHistoryUnknown() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store; _ = try addRate(store, currency: "USD", input: "2", output: "4")
            let id = try #require(store.runAI(action: fixture.action, draft: store.createDraft(input: "Synthetic restore race")))
            try await fixture.drain(id)
            let index = try #require(store.tasks.firstIndex { $0.id == id }), live = try #require(store.tasks[index].aiUsageSummary)
            store.tasks[index].restoredFromReceipt = true; store.tasks[index].aiUsageSummary = .unknown
            let gate = SourceRemovalGate(), reader = UsageRestoreReadProbe(metadata: store.usageMetadataStore, id: id, gate: gate)
            let restore = store.loadRestoredAIUsage(id, interrupted: false, reader: { await reader.direct() })
            do {
                try await storeEventually { await gate.entered }
                try await saveUnrelatedMetadata(store)
                await gate.release(); await restore.value
                #expect(store.tasks[index].aiUsageSummary == live)
                let reads = await reader.reads; #expect(reads == 2)
                let stats = try await fixture.server.stats(); #expect(stats["post_requests"] == 1)
            } catch { await gate.release(); await restore.value; throw error }
        }
    }
    @Test func unrelatedWriteRereadsWorkflowFamilyAndClearStillRejectsOldRead() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store; _ = try addRate(store, currency: "USD", input: "2", output: "4")
            let flow = WorkflowDefinition(name: "Synthetic restore family race", steps: [.init(operation: .aiAction(fixture.action.id))])
            let id = try #require(store.runWorkflow(flow, input: "Synthetic input"))
            try await fixture.drain(id)
            let index = try #require(store.tasks.firstIndex { $0.id == id }), live = try #require(store.tasks[index].aiUsageSummary)
            store.tasks[index].restoredFromReceipt = true; store.tasks[index].aiUsageSummary = .unknown
            let gate = SourceRemovalGate(), reader = UsageRestoreReadProbe(metadata: store.usageMetadataStore, id: id, gate: gate)
            let restore = store.loadRestoredWorkflowUsage(id, reader: { try await reader.family() })
            do {
                try await storeEventually { await gate.entered }; try await saveUnrelatedMetadata(store)
                await gate.release(); await restore.value
                #expect(store.tasks[index].aiUsageSummary == live)
                let reads = await reader.reads; #expect(reads == 2)
            } catch { await gate.release(); await restore.value; throw error }
            store.tasks[index].aiUsageSummary = .unknown
            let clearGate = SourceRemovalGate(), oldReader = UsageRestoreReadProbe(metadata: store.usageMetadataStore, id: id, gate: clearGate)
            let old = store.loadRestoredWorkflowUsage(id, reader: { try await oldReader.family() })
            do {
                try await storeEventually { await clearGate.entered }
                await store.clearAIUsageHistory()
                await clearGate.release(); await old.value
                #expect(store.tasks[index].aiUsageSummary == .unknown)
                let reads = await oldReader.reads; #expect(reads == 1)
            } catch { await clearGate.release(); await old.value; throw error }
        }
    }
    @Test func analysisClearAndNewerQueriesRejectLateSnapshots() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store; _ = try addRate(store, currency: "USD", input: "2", output: "4")
            let id = try #require(store.runAI(action: fixture.action, draft: store.createDraft(input: "Synthetic analysis race")))
            try await fixture.drain(id)
            let gate = SourceRemovalGate(), reader = UsageRestoreReadProbe(metadata: store.usageMetadataStore, id: id, gate: gate)
            let old = Task { await store.refreshAIUsageAnalysis(days: 7, reader: { try await reader.analysis(from: $0, to: $1) }) }
            do {
                try await storeEventually { await gate.entered }
                await store.refreshAIUsageAnalysis(days: 30)
                let newer = try #require(store.usageAnalysisReport)
                #expect(newer.calls == 1 && newer.amounts.first?.amount == "0.000044")
                await gate.release(); await old.value
                #expect(store.usageAnalysisReport?.from == newer.from)
            } catch { await gate.release(); await old.value; throw error }
            let clearGate = SourceRemovalGate(), oldReader = UsageRestoreReadProbe(metadata: store.usageMetadataStore, id: id, gate: clearGate)
            let clearing = Task { await store.refreshAIUsageAnalysis(days: 7, reader: { try await oldReader.analysis(from: $0, to: $1) }) }
            do {
                try await storeEventually { await clearGate.entered }; await store.clearAIUsageHistory()
                await clearGate.release(); await clearing.value
                #expect(store.usageAnalysisReport == nil && !store.usageAnalysisLoading)
                let reads = await oldReader.reads; #expect(reads == 1)
                await store.refreshAIUsageAnalysis(days: 7)
                #expect(store.usageAnalysisReport?.calls == 0 && store.usageAnalysisReport?.amounts.isEmpty == true)
            } catch { await clearGate.release(); await clearing.value; throw error }
        }
    }
    @Test func analysisRereadsUnrelatedWritesAndMaintenanceInvalidatesPublishedResults() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store
            let id = try #require(store.runAI(action: fixture.action, draft: store.createDraft(input: "Synthetic analysis refresh")))
            try await fixture.drain(id)
            let gate = SourceRemovalGate(), reader = UsageRestoreReadProbe(metadata: store.usageMetadataStore, id: id, gate: gate)
            let task = Task { await store.refreshAIUsageAnalysis(days: 7, reader: { try await reader.analysis(from: $0, to: $1) }) }
            do {
                try await storeEventually { await gate.entered }
                // 暂停UI维护回调，只验证全局revision重读；随后显式调用同一生产处理器。
                await store.usageMetadataStore.setReportHandler { _ in }
                try await saveUnrelatedMetadata(store)
                await gate.release(); await task.value
                #expect(store.usageAnalysisReport?.calls == 1 && store.usageAnalysisReport?.invalidRecords == 1)
                let reads = await reader.reads; #expect(reads == 2)
                let report = await store.usageMetadataStore.maintain()
                store.handleUsageMaintenance(report)
                #expect(store.usageAnalysisReport == nil)
            } catch { await gate.release(); await task.value; throw error }
        }
    }
    private func saveUnrelatedMetadata(_ store: WorkbenchModel) async throws {
        let id = UUID(), data = try JSONSerialization.data(withJSONObject: ["runID": id.uuidString, "recordedAt": Date().timeIntervalSinceReferenceDate])
        let result = await store.usageMetadataStore.save(id: id, data: data)
        #expect(result.stored)
    }
    private func addRate(_ store: WorkbenchModel, model: String? = nil, currency: String, input: String, output: String) throws -> AIRateDefinition {
        let rate = AIRateDefinition(endpointFingerprint: AIServiceIdentity.fingerprint(URL(string: store.configuration.endpoint)!), model: model ?? store.configuration.model, currency: currency, inputPerMillion: input, outputPerMillion: output)
        #expect(store.saveAIRate(rate, replacing: nil))
        return try #require(store.configuration.aiRates.first { $0.id == rate.id })
    }
}
