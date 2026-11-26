import Foundation
import Testing
import ExecutionCore
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct HistoryManagementTests {
    @Test func clearRemovesEndedRowsDraftsAndWindowReferencesButKeepsActiveInput() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, finished = UUID(), closing = UUID()
        let idle = store.createDraft(input: "Synthetic idle input"), active = store.createDraft(input: "Synthetic active input")
        try await store.invocationStore.begin(id: finished, name: "Synthetic ended")
        try await store.invocationStore.finish(id: finished, result: .init(state: .succeeded))
        await store.invocationStore.releaseProtection(for: finished)
        store.tasks.append(.init(id: finished, title: "Synthetic ended", state: .completed, output: "Synthetic output", finishedAt: Date(), draftID: idle.id))
        idle.latestRunID = finished; store.latestAutoCopyRunID = finished; store.proposalRequests[idle.id] = finished
        #expect(store.reserveExecution(closing, draft: active))
        store.tasks.append(.init(id: closing, title: "Synthetic closing", state: .completed, finishedAt: Date(), draftID: active.id))
        let launcher = LauncherSession(store: store), workspace = WorkspaceSession(), settings = SettingsSession(store: store)
        launcher.draft = idle; launcher.setVisible(true)
        workspace.draft = idle; workspace.selectedTaskID = finished; workspace.setVisible(true, in: store)
        settings.editedCommandSourceRunID = finished; settings.editedCommand = .init(name: "Synthetic review", executable: "/usr/bin/printf"); settings.setVisible(true)
        store.onHistoryRemoved = { taskIDs, draftIDs in
            launcher.removeHistory(draftIDs: draftIDs); workspace.removeHistory(taskIDs: taskIDs, draftIDs: draftIDs, in: store); settings.removeHistory(taskIDs: taskIDs)
        }
        await store.clearFinishedHistory()
        #expect(store.tasks.map(\.id) == [closing] && store.ownsDraft(active))
        #expect(idle.isDiscarded && idle.input.isEmpty && idle.latestRunID == nil)
        #expect(launcher.draft == nil && workspace.draft == nil && workspace.selectedTaskID == closing)
        #expect(settings.editedCommand == nil && store.proposalRequests.isEmpty && store.latestAutoCopyRunID == nil)
        #expect(await store.invocationStore.list().isEmpty)
        store.finishExecutionReservation(closing)
        await fixture.cleanup()
    }

    @Test func failedReceiptClearKeepsItsGroupAndAllowsOtherGroupsToClear() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, cliID = UUID(), aiID = UUID()
        for (sink, id) in [(store.invocationStore, cliID), (store.aiInvocationStore, aiID)] {
            try await sink.begin(id: id, name: "Synthetic ended")
            try await sink.finish(id: id, result: .init(state: .succeeded))
            await sink.releaseProtection(for: id)
        }
        store.tasks.append(.init(id: cliID, title: "Synthetic CLI", state: .completed, finishedAt: Date()))
        var ai = RunningTaskItem(id: aiID, title: "Synthetic AI", state: .completed, finishedAt: Date()); ai.aiUsageSummary = .unknown; store.tasks.append(ai)
        // 仅破坏本测试拥有的落盘目标，制造真实rename失败；不得删除用户文件。
        let target = fixture.directory.appendingPathComponent("invocations/invocations.json")
        let original = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        await store.clearFinishedHistory()
        #expect(store.tasks.contains { $0.id == cliID } && !store.tasks.contains { $0.id == aiID })
        let retainedCLI = await store.invocationStore.list()
        #expect(!store.settingsNotice.isEmpty && retainedCLI.map(\.id) == [cliID])
        #expect(await store.aiInvocationStore.list().isEmpty)
        try FileManager.default.removeItem(at: target); try original.write(to: target)
        await store.clearFinishedHistory()
        let clearedCLI = await store.invocationStore.list()
        #expect(store.tasks.isEmpty && clearedCLI.isEmpty)
        await fixture.cleanup()
    }

    @Test func emptyClearInvalidatesAlreadyFetchedStartupHistory() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        #expect(fixture.store.receiptMaintenanceTask != nil)
        let oldGeneration = fixture.store.historyGeneration
        let old = InvocationReceipt(id: UUID(), name: "Synthetic late snapshot", state: .succeeded, finishedAt: Date())
        await fixture.store.clearFinishedHistory()
        fixture.store.restoreHistorySnapshot(cli: [old], ai: [], generation: oldGeneration)
        #expect(fixture.store.tasks.isEmpty)
        #expect(fixture.store.receiptMaintenanceTask != nil)
        await fixture.cleanup()
    }

    @Test func clearCompletionPreservesInputEditedAfterTheConfirmationSnapshot() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let changed = fixture.store.createDraft(input: "Synthetic original"), idle = fixture.store.createDraft(input: "Synthetic idle")
        let snapshot = [changed.id: changed.revision, idle.id: idle.revision]
        changed.editInput("Synthetic newly entered input")
        let kept = fixture.store.applyConfirmedHistoryClear(taskIDs: [], draftRevisions: snapshot)
        #expect(kept == 1 && fixture.store.ownsDraft(changed) && changed.input == "Synthetic newly entered input")
        #expect(idle.isDiscarded && idle.input.isEmpty)
        await fixture.cleanup()
    }

    @Test func deletedDraftCannotReadClipboardOrStartAnyAIEntry() async throws {
        var reads = 0
        let fixture = try RetentionFixture(allowContextCapture: true, reader: { reads += 1; return "Synthetic clipboard" }); defer { Task { await fixture.cleanup() } }
        let draft = fixture.store.createDraft(input: "Synthetic retained input")
        fixture.store.useClipboardInput(draft)
        #expect(reads == 1 && draft.input == "Synthetic clipboard")
        fixture.store.removeSessionObjects(tasks: [], drafts: [draft.id])
        fixture.store.useClipboardInput(draft)
        #expect(fixture.store.runAI(action: .init(name: "Synthetic", prompt: "Synthetic"), draft: draft) == nil)
        fixture.store.generateCommandProposal(draft: draft); fixture.store.runReadOnlyAgent(draft: draft)
        #expect(reads == 1 && draft.input.isEmpty && fixture.store.tasks.isEmpty && fixture.store.taskHandles.isEmpty)
        await fixture.cleanup()
    }

    @Test func usageClearRemovesDiskAndCachedCountsAndRejectsLateRecovery() async throws {
        try await withStoreHTTPFixture(path: "usage") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic clear usage")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            try await fixture.drain(id)
            #expect(fixture.store.tasks.first { $0.id == id }?.aiUsageSummary?.state == .reported)
            let oldUsageGeneration = fixture.store.usageHistoryGeneration
            let oldUsageRead = fixture.store.captureUsageRestoreRead()
            let previous = try #require(fixture.store.tasks.first { $0.id == id }?.aiUsageSummary)
            await fixture.store.clearAIUsageHistory()
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("usage/" + id.uuidString + ".json").path))
            #expect(fixture.store.tasks.first { $0.id == id }?.aiUsageSummary == .unknown)
            let index = try #require(fixture.store.tasks.firstIndex { $0.id == id })
            fixture.store.tasks[index].restoredFromReceipt = true
            fixture.store.applyRestoredAIUsage(previous, id: id, historyGeneration: fixture.store.historyGeneration, usageGeneration: oldUsageGeneration, usageRead: oldUsageRead)
            #expect(fixture.store.tasks[index].aiUsageSummary == .unknown)
            #expect(!fixture.store.settingsNotice.isEmpty)
            // 用量清除与任务正文、配置分离。
            #expect(fixture.store.tasks.first { $0.id == id }?.output.isEmpty == false && fixture.store.ownsDraft(draft))
        }
    }

    @Test func usageSavedDuringReceiptClosingIsRemovedFromBothDiskAndCache() async throws {
        try await withStoreHTTPFixture(path: "usage") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic closing usage")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            try await fixture.drain(id)
            // 构造终态已写usage、回执仍收口的生产阶段，不发送第二个请求。
            fixture.store.executionReservations.insert(id)
            await fixture.store.clearAIUsageHistory()
            #expect(fixture.store.tasks.first { $0.id == id }?.aiUsageSummary == .unknown)
            #expect(fixture.store.invalidatedUsageRuns.contains(id))
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("usage/" + id.uuidString + ".json").path))
            fixture.store.finishExecutionReservation(id)
        }
    }

    @Test func automaticExpirationAlsoInvalidatesCachedUsageAndLateReaders() async throws {
        try await withStoreHTTPFixture(path: "usage") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic expiring usage")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            try await fixture.drain(id)
            let index = try #require(fixture.store.tasks.firstIndex { $0.id == id })
            let previous = try #require(fixture.store.tasks[index].aiUsageSummary)
            #expect(previous.state == .reported && previous.reportedInputTokens == 12 && previous.reportedOutputTokens == 5)
            let oldUsageRead = fixture.store.captureUsageRestoreRead()
            let file = fixture.directory.appendingPathComponent("usage/" + id.uuidString + ".json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["recordedAt"] = Date().addingTimeInterval(-91 * 86_400).timeIntervalSinceReferenceDate
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            let report = await fixture.store.usageMetadataStore.maintain()
            #expect(report.removedIDs == [id])
            try await storeEventually { fixture.store.tasks[index].aiUsageSummary == .unknown }
            fixture.store.tasks[index].restoredFromReceipt = true
            fixture.store.applyRestoredAIUsage(previous, id: id, historyGeneration: fixture.store.historyGeneration, usageGeneration: fixture.store.usageHistoryGeneration, usageRead: oldUsageRead)
            #expect(fixture.store.tasks[index].aiUsageSummary == .unknown)
        }
    }
}
