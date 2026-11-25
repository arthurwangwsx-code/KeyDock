import Foundation
import AICore

struct WorkflowUsageLink: Codable, Equatable, Sendable {
    let childRunID: UUID
    let workflowStepID: UUID
}
struct WorkflowUsageIndex: Codable, Sendable {
    let kind: String
    let formatVersion: Int
    let runID: UUID
    let recordedAt: Date
    let children: [WorkflowUsageLink]
    let hasIncompleteRecords: Bool
    init(runID: UUID, children: [WorkflowUsageLink], hasIncompleteRecords: Bool) {
        kind = "workflowIndex"; formatVersion = 2; self.runID = runID; recordedAt = Date()
        self.children = children; self.hasIncompleteRecords = hasIncompleteRecords
    }
    var isValid: Bool {
        kind == "workflowIndex" && formatVersion == 2 && recordedAt.timeIntervalSinceReferenceDate.isFinite && children.count <= 128 &&
        Set(children.map(\.childRunID)).count == children.count && Set(children.map(\.workflowStepID)).count == children.count &&
        !children.contains { $0.childRunID == runID }
    }
}
struct WorkflowUsageChild {
    let stepID: UUID
    let recorded: AIRecordedUsage
    let savedRevision: UInt64
}
struct WorkflowUsageState {
    var children: [UUID: WorkflowUsageChild] = [:]
    var unsaved: Set<UUID> = []
    var incomplete = false
}
struct WorkflowUsageRead: Sendable {
    let revision: UInt64
    let recorded: AIRecordedUsage
    let links: [WorkflowUsageLink]
}

enum WorkflowUsageAggregation {
    static func combine(_ records: [AIRecordedUsage], incomplete: Bool) -> AIRecordedUsage {
        var result = AIRecordedUsage(incomplete: incomplete), seen: Set<UUID> = []
        for record in records {
            result.overflowed = result.overflowed || record.overflowed
            result.incomplete = result.incomplete || record.incomplete
            for call in record.calls {
                guard seen.insert(call.attemptID).inserted else { result.incomplete = true; continue }
                guard result.calls.count < 128 else { result.overflowed = true; continue }
                result.calls.append(call)
            }
        }
        return result
    }
    static func summary(_ recorded: AIRecordedUsage, running: Bool) -> AIUsageSummary {
        if !running && recorded.calls.isEmpty && !recorded.incomplete && !recorded.overflowed { return .notRequested }
        var value = recorded; value.incomplete = value.incomplete || running
        return AIUsageFacts.recorded(value, outcome: running ? "running" : "succeeded").summary
    }
}

extension AIUsageMetadataStore {
    /// 单次actor操作读取一个family，不跨await拼接清除前后的子记录，也不递归跟随索引。
    func readWorkflowUsage(id: UUID) throws -> WorkflowUsageRead {
        let revision = revisionFence.current
        guard let data = read(id: id).data, let index = try? JSONDecoder().decode(WorkflowUsageIndex.self, from: data), index.runID == id, index.isValid else {
            return .init(revision: revision, recorded: .init(incomplete: true), links: [])
        }
        var records: [AIRecordedUsage] = [], missing = index.hasIncompleteRecords
        for link in index.children {
            try Task.checkCancellation()
            guard let data = read(id: link.childRunID).data,
                  let record = AIUsageLedgerReader.recordedCalls(data: data, runID: link.childRunID, parentRunID: id, stepID: link.workflowStepID) else { missing = true; continue }
            records.append(record)
        }
        return .init(revision: revision, recorded: WorkflowUsageAggregation.combine(records, incomplete: missing), links: index.children)
    }
}

extension WorkbenchModel {
    func retainWorkflowUsage(parent: UUID, child: UUID, step: UUID, recorded: AIRecordedUsage, savedRevision: UInt64 = 0) {
        guard var state = workflowAIUsage[parent], !isShuttingDown || executionReservations.contains(parent) else { return }
        state.children[child] = .init(stepID: step, recorded: recorded, savedRevision: savedRevision)
        if savedRevision > 0 { state.unsaved.remove(child) } else { state.unsaved.insert(child) }
        workflowAIUsage[parent] = state
        workflowUsageDependencies[parent] = state.children.mapValues(\.savedRevision)
        let records = state.children.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { state.children[$0]?.recorded }
        let summary = WorkflowUsageAggregation.summary(WorkflowUsageAggregation.combine(records, incomplete: state.incomplete), running: tasks.first { $0.id == parent }?.isRunning == true)
        publishWorkflowUsage(summary, id: parent)
    }
    func markWorkflowUsageSaved(parent: UUID, child: UUID, revision: UInt64, stored: Bool) {
        guard var state = workflowAIUsage[parent] else { return }
        if stored {
            if let value = state.children[child] {
                state.children[child] = .init(stepID: value.stepID, recorded: value.recorded, savedRevision: revision)
                state.unsaved.remove(child)
            }
        } else { state.unsaved.insert(child) }
        workflowAIUsage[parent] = state
        workflowUsageDependencies[parent] = state.children.mapValues(\.savedRevision)
    }
    private func publishWorkflowUsage(_ summary: AIUsageSummary, id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].aiUsageSummary = summary; usageSummaryGenerations[id] = usageHistoryGeneration; invalidatedUsageRuns.remove(id)
        usageSummaryRevisions[id] = 0
    }
    func finishWorkflowUsage(_ id: UUID) async {
        guard let state = workflowAIUsage.removeValue(forKey: id) else { return }
        workflowUsageDependencies[id] = state.children.mapValues(\.savedRevision)
        let keys = state.children.keys.sorted { $0.uuidString < $1.uuidString }
        let index = WorkflowUsageIndex(runID: id, children: keys.compactMap { child in state.children[child].map { .init(childRunID: child, workflowStepID: $0.stepID) } }, hasIncompleteRecords: state.incomplete || !state.unsaved.isEmpty)
        let recorded = WorkflowUsageAggregation.combine(keys.compactMap { state.children[$0]?.recorded }, incomplete: state.incomplete)
        publishWorkflowUsage(WorkflowUsageAggregation.summary(recorded, running: false), id: id)
        do {
            let result = await usageMetadataStore.save(id: id, data: try JSONEncoder().encode(index))
            if !result.stored { workspaceNoticeMessage = noticeKey("Usage metadata could not be saved") }
        } catch { workspaceNoticeMessage = noticeKey("Usage metadata could not be saved") }
    }
    func invalidateWorkflowUsage(_ ids: Set<UUID>, revision: UInt64, remaining: Set<UUID>? = nil) {
        var affected: Set<UUID> = []
        for parent in Array(workflowAIUsage.keys) {
            guard var state = workflowAIUsage[parent] else { continue }
            let removed = state.children.keys.filter { child in
                let absent = remaining.map { !$0.contains(child) } ?? ids.contains(child)
                return absent && state.children[child]!.savedRevision <= revision
            }
            if !removed.isEmpty {
                for id in removed { state.children[id] = nil; state.unsaved.remove(id) }
                state.incomplete = true; workflowAIUsage[parent] = state
                affected.insert(parent)
            }
        }
        for parent in workflowUsageDependencies.keys where workflowAIUsage[parent] == nil {
            let children = workflowUsageDependencies[parent, default: [:]]
            if children.contains(where: { child, savedRevision in
                let absent = remaining.map { !$0.contains(child) } ?? ids.contains(child)
                return absent && savedRevision <= revision
            }) { affected.insert(parent) }
        }
        for parent in affected {
            if let index = tasks.firstIndex(where: { $0.id == parent }) { tasks[index].aiUsageSummary = .unknown; invalidatedUsageRuns.insert(parent) }
        }
    }
    @discardableResult func loadRestoredWorkflowUsage(_ id: UUID,
        reader: (@Sendable () async throws -> WorkflowUsageRead)? = nil) -> Task<Void, Never> {
        let history = historyGeneration, usage = usageHistoryGeneration, metadata = usageMetadataStore
        return Task { [weak self] in
            for _ in 0..<3 {
                guard let self, canAcceptRestoredUsage(id, history: history, usage: usage) else { return }
                let read: WorkflowUsageRead
                do { read = if let reader { try await reader() } else { try await metadata.readWorkflowUsage(id: id) } }
                catch { return }
                let summary = await Task.detached(priority: .utility) { WorkflowUsageAggregation.summary(read.recorded, running: false) }.value
                guard canAcceptRestoredUsage(id, history: history, usage: usage) else { return }
                guard metadata.revisionFence.current == read.revision else { continue }
                guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
                workflowUsageDependencies[id] = Dictionary(uniqueKeysWithValues: read.links.map { ($0.childRunID, read.revision) })
                tasks[index].aiUsageSummary = summary; usageSummaryGenerations[id] = usage
                usageSummaryRevisions[id] = read.revision
                return
            }
        }
    }
}
