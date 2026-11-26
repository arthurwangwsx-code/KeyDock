import Foundation
import Darwin
import Testing
import AICore
import ExecutionCore
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct UsageRetentionBudgetTests {
    @Test func automaticExpirationRedactsBudgetBeforeDelayedReportAndOldReceiptRestore() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, id = UUID()
            let definition = RunDefinitionReference(kind: .agent, definitionID: UUID(), definitionVersion: 1, fingerprint: String(repeating: "a", count: 64))
            let begun = try await store.aiInvocationStore.begin(id: id, name: "Agent run", runDefinition: definition, runTokenBudget: .init(maximumTokens: 100))
            try await store.aiInvocationStore.finish(id: id, result: .init(state: .succeeded),
                runTokenBudget: .init(maximumTokens: 100, knownTokens: 31, completedTurns: 2, status: .verified), expectedRunStamp: begun.runStamp)
            await store.aiInvocationStore.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
            let old = try #require(await store.aiInvocationStore.list().first { $0.id == id })
            let ticket = store.captureUsageRestoreRead()
            struct Synthetic: Encodable { let runID: UUID; let recordedAt: Date; let unknown: Bool }
            let directory = fixture.directory.appendingPathComponent("usage")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(id.uuidString + ".json")
            try JSONEncoder().encode(Synthetic(runID: id, recordedAt: Date().addingTimeInterval(-91 * 86_400), unknown: true)).write(to: file)
            // 不发送MainActor回调，模拟actor已完成删除而报告尚在排队。
            await store.usageMetadataStore.setReportHandler { _ in }
            let report = await store.usageMetadataStore.maintain()
            #expect(report.removedIDs == [id] && !FileManager.default.fileExists(atPath: file.path))
            let disk = try #require(await store.aiInvocationStore.list().first { $0.id == id })
            #expect(disk.runTokenBudget?.knownTokens == nil && disk.runTokenBudget?.completedTurns == 0)
            #expect(disk.runTokenBudget?.maximumTokens == 100 && disk.runAttempt == old.runAttempt)
            store.tasks.removeAll { $0.id == id }
            store.restoreHistorySnapshot(cli: [], ai: [old], generation: store.historyGeneration, usageRead: ticket)
            let restored = try #require(store.tasks.first { $0.id == id })
            #expect(restored.runTokenBudget?.knownTokens == nil && restored.runTokenBudget?.completedTurns == 0)
            #expect(restored.runTokenBudget?.maximumTokens == 100 && restored.runAttempt == old.runAttempt)
            #expect(store.taskHandles.isEmpty && store.executionReservations.isEmpty && store.pendingApprovals.isEmpty)
        }
    }
}

private enum BudgetRetentionMode: CaseIterable { case ttl, count, bytes }
private actor RetentionPause {
    private var armed = false
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func arm() { armed = true; entered = false }
    func waitIfArmed() async {
        guard armed else { return }; armed = false; entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { armed = false; continuation?.resume(); continuation = nil }
}
private final class RetentionIOFault: @unchecked Sendable {
    private let lock = NSLock()
    private var point: InvocationPersistencePoint?
    private var failUnlink = false, failSync = false
    private(set) var unlinkCalls = 0
    func arm(_ value: InvocationPersistencePoint) { lock.withLock { point = value } }
    func armUnlink() { lock.withLock { failUnlink = true } }
    func armSync() { lock.withLock { failSync = true } }
    func code(_ value: InvocationPersistencePoint) -> Int32? {
        lock.withLock { guard point == value else { return nil }; point = nil; return EIO }
    }
    func unlink(_ descriptor: Int32, _ name: String) throws {
        let failed = lock.withLock { unlinkCalls += 1; let value = failUnlink; failUnlink = false; return value }
        guard !failed, unlinkat(descriptor, name, 0) == 0 else { throw POSIXError(.EIO) }
    }
    func sync(_ descriptor: Int32) throws {
        let failed = lock.withLock { let value = failSync; failSync = false; return value }
        guard !failed, fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
    var unlinks: Int { lock.withLock { unlinkCalls } }
}

@MainActor private func withBudgetRetentionFixture(_ options: AIUsageStorageDependencies = .init(), fault: RetentionIOFault? = nil,
    _ body: @MainActor (WorkflowIntegrationFixture) async throws -> Void) async throws {
    let fixture = try WorkflowIntegrationFixture(usageStorage: options, invocationPersistenceFault: { domain, point in domain == "ai" ? fault?.code(point) : nil })
    await fixture.stopAutomaticWork()
    do { try await body(fixture); await fixture.cleanup() }
    catch { await fixture.cleanup(); throw error }
}
@MainActor private func seedRetentionBudget(_ fixture: WorkflowIntegrationFixture, id: UUID = UUID(), release: Bool = true) async throws -> InvocationWorkerOwnership {
    try await seedRetentionBudget(in: fixture.store, id: id, release: release)
}
@MainActor private func seedRetentionBudget(in store: WorkbenchModel, id: UUID = UUID(), release: Bool = true) async throws -> InvocationWorkerOwnership {
    let core = store.aiInvocationStore
    let definition = RunDefinitionReference(kind: .agent, definitionID: UUID(), definitionVersion: 1, fingerprint: String(repeating: "b", count: 64))
    let begun = try await core.begin(id: id, name: "Agent run", runDefinition: definition, runTokenBudget: .init(maximumTokens: 100))
    let owner = InvocationWorkerOwnership(store: core, begun: begun)
    try await owner.finish(.init(state: .succeeded), runTokenBudget: .init(maximumTokens: 100, knownTokens: 31, completedTurns: 2, status: .verified))
    if release { await owner.release() }
    return owner
}
private func retentionRecord(_ id: UUID, at date: Date, padding: Int = 0) throws -> Data {
    struct Synthetic: Encodable { let runID: UUID; let recordedAt: Date; let unknown: Bool; let padding: String }
    return try JSONEncoder().encode(Synthetic(runID: id, recordedAt: date, unknown: true, padding: String(repeating: "x", count: padding)))
}
@MainActor @discardableResult private func putRetentionRecord(_ fixture: WorkflowIntegrationFixture, _ id: UUID, at date: Date) throws -> URL {
    let directory = fixture.directory.appendingPathComponent("usage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent(id.uuidString + ".json")
    try retentionRecord(id, at: date).write(to: file)
    return file
}

extension UsageRetentionBudgetTests {
    @Test func ownerReleasedBetweenClearPhasesResolvesDeferredReport() async throws {
        let pause = RetentionPause(), id = UUID()
        var options = AIUsageStorageDependencies()
        options.beforePrepare = { ids, _ in if ids.contains(id) { await pause.waitIfArmed() } }
        try await withBudgetRetentionFixture(options) { fixture in
            let owner = try await seedRetentionBudget(fixture, id: id, release: false)
            let file = try putRetentionRecord(fixture, id, at: Date())
            await pause.arm()
            let clearing = Task { await fixture.store.usageMetadataStore.clear() }
            do {
                try await fixture.eventually { await pause.entered }
                #expect(await fixture.store.aiInvocationStore.list().first { $0.id == id }?.runTokenBudget?.knownTokens == 31)
                await owner.release(); await pause.release()
                let report = await clearing.value
                #expect(report.isComplete && report.deferredIDs.isEmpty && report.removedIDs == [id] && report.budgetRedactedIDs == [id])
                #expect(!FileManager.default.fileExists(atPath: file.path))
            } catch { await pause.release(); _ = await clearing.value; throw error }
        }
    }

    @Test func realModelFactsQueuedAfterClearBoundaryAreRetained() async throws {
        let pause = RetentionPause(), oldID = UUID()
        var options = AIUsageStorageDependencies()
        options.beforePrepare = { ids, _ in if ids.contains(oldID) { await pause.waitIfArmed() } }
        try await withStoreHTTPFixture(path: "stream", usageStorage: options) { fixture in
            let store = fixture.store
            let old = try await seedRetentionBudget(in: store, id: oldID)
            let directory = fixture.directory.appendingPathComponent("usage")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let oldFile = directory.appendingPathComponent(old.id.uuidString + ".json")
            try retentionRecord(old.id, at: Date()).write(to: oldFile)
            await pause.arm()
            let clearing = Task { await store.clearAIUsageHistory() }
            var newID: UUID?
            do {
                try await storeEventually { await pause.entered }
                let before = fixture.directory.appendingPathComponent("reopen-before-unlink")
                try FileManager.default.createDirectory(at: before, withIntermediateDirectories: false)
                try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("ai-invocations/invocations.json"),
                    to: before.appendingPathComponent("invocations.json"))
                let reopenedBefore = try InvocationStore(directory: before)
                #expect(await reopenedBefore.list().first { $0.id == oldID }?.runTokenBudget?.knownTokens == nil)
                #expect(FileManager.default.fileExists(atPath: oldFile.path))
                let draft = store.createDraft(input: "Synthetic new facts after clear began")
                let id = try #require(store.runAI(action: fixture.action, draft: draft)); newID = id
                try await storeEventually { await store.usageMetadataStore.pendingMutationCount > 0 }
                #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".json").path))
                await pause.release(); await clearing.value
                try await fixture.drain(id)
                let task = try #require(store.tasks.first { $0.id == id })
                #expect(task.status == .completed && task.aiUsageSummary?.state == .reported)
                #expect(task.aiUsageSummary?.reportedInputTokens != nil && task.aiUsageSummary?.reportedOutputTokens != nil)
                #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".json").path))
                #expect(!FileManager.default.fileExists(atPath: oldFile.path))
                let after = fixture.directory.appendingPathComponent("reopen-after-unlink")
                try FileManager.default.createDirectory(at: after, withIntermediateDirectories: false)
                try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("ai-invocations/invocations.json"),
                    to: after.appendingPathComponent("invocations.json"))
                let reopenedAfter = try InvocationStore(directory: after)
                #expect(await reopenedAfter.list().first { $0.id == oldID }?.runTokenBudget?.knownTokens == nil)
                let stats = try await fixture.server.stats(); #expect(stats["post_requests"] == 1)
            } catch {
                await pause.release(); await clearing.value
                if let newID { store.cancelTask(newID); try? await fixture.drain(newID) }
                throw error
            }
        }
    }

    @Test func queuedSaveThenClearRespectFIFO() async throws {
        let pause = RetentionPause(), id = UUID(), next = UUID()
        var options = AIUsageStorageDependencies()
        options.beforePrepare = { ids, _ in if ids.contains(id) { await pause.waitIfArmed() } }
        try await withBudgetRetentionFixture(options) { fixture in
            _ = try await seedRetentionBudget(fixture, id: id)
            try putRetentionRecord(fixture, id, at: Date())
            await pause.arm()
            let first = Task { await fixture.store.usageMetadataStore.clear() }
            var saving: Task<AIUsageMetadataWriteResult, Never>?, last: Task<AIUsageMaintenanceReport, Never>?
            do {
                try await fixture.eventually { await pause.entered }
                let data = try retentionRecord(next, at: Date())
                saving = Task { await fixture.store.usageMetadataStore.save(id: next, data: data) }
                try await fixture.eventually { await fixture.store.usageMetadataStore.pendingMutationCount == 1 }
                last = Task { await fixture.store.usageMetadataStore.clear() }
                try await fixture.eventually { await fixture.store.usageMetadataStore.pendingMutationCount == 2 }
                await pause.release(); _ = await first.value
                let saved = try #require(await saving?.value), cleared = try #require(await last?.value)
                #expect(saved.stored && cleared.isComplete && cleared.removedIDs == [next])
                #expect(await fixture.store.usageMetadataStore.read(id: next).data == nil)
            } catch { await pause.release(); _ = await first.value; _ = await saving?.value; _ = await last?.value; throw error }
        }
    }

    @Test(arguments: BudgetRetentionMode.allCases)
    private func realEvictionClearsOnlySelectedBudget(_ mode: BudgetRetentionMode) async throws {
        let now = Date(), first = UUID(), second = UUID()
        var options = AIUsageStorageDependencies()
        options.clock = { now }
        if mode == .count { options.policy.maximumCount = 1 }
        if mode == .bytes { options.policy.maximumTotalBytes = UInt64(try retentionRecord(second, at: now).count) }
        try await withBudgetRetentionFixture(options) { fixture in
            let a = try await seedRetentionBudget(fixture, id: first), b = try await seedRetentionBudget(fixture, id: second)
            let old = try #require(await fixture.store.aiInvocationStore.list().first { $0.id == a.id })
            try putRetentionRecord(fixture, a.id, at: now.addingTimeInterval(mode == .ttl ? -91 * 86_400 : -100))
            try putRetentionRecord(fixture, b.id, at: now)
            let report = await fixture.store.usageMetadataStore.maintain()
            #expect(report.isComplete && report.removedIDs == [a.id] && report.budgetRedactedIDs == [a.id] && report.remainingIDs == [b.id])
            let rows = await fixture.store.aiInvocationStore.list()
            let cleared = try #require(rows.first { $0.id == a.id }), kept = try #require(rows.first { $0.id == b.id })
            #expect(cleared.runTokenBudget?.knownTokens == nil && cleared.runTokenBudget?.completedTurns == 0 && cleared.runTokenBudget?.maximumTokens == 100)
            #expect(cleared.runAttempt == old.runAttempt && kept.runTokenBudget?.knownTokens == 31 && kept.runTokenBudget?.completedTurns == 2)
        }
    }

    @Test func terminalLiveRecordCountsCapacityAndHostReleaseRetriesIt() async throws {
        var options = AIUsageStorageDependencies(); options.policy.maximumCount = 1
        try await withBudgetRetentionFixture(options) { fixture in
            let owner = try await seedRetentionBudget(fixture, release: false), next = UUID()
            let file = try putRetentionRecord(fixture, owner.id, at: Date().addingTimeInterval(-91 * 86_400))
            let report = await fixture.store.usageMetadataStore.maintain()
            #expect(!report.isComplete && report.deferredIDs == [owner.id] && report.remainingCount == 1 && report.removedIDs.isEmpty)
            let before = try #require(await fixture.store.aiInvocationStore.list().first { $0.id == owner.id })
            #expect(before.runTokenBudget?.knownTokens == 31)
            let rejected = await fixture.store.usageMetadataStore.save(id: next, data: try retentionRecord(next, at: Date()))
            #expect(!rejected.stored && rejected.report.problems.contains(.capacityExceeded))
            #expect(FileManager.default.fileExists(atPath: file.path))
            fixture.store.executionReservations.insert(owner.id)
            fixture.store.finishExecutionReservation(owner.id, owner: owner)
            try await fixture.eventually { !FileManager.default.fileExists(atPath: file.path) }
            let after = try #require(await fixture.store.aiInvocationStore.list().first { $0.id == owner.id })
            #expect(after.runTokenBudget?.knownTokens == nil && after.runAttempt == before.runAttempt)
            let accepted = await fixture.store.usageMetadataStore.save(id: next, data: try retentionRecord(next, at: Date()))
            #expect(accepted.stored && accepted.report.remainingIDs == [next])
        }
    }

    @Test(arguments: [InvocationPersistencePoint.beforeWrite, .afterRename])
    func coreFailureDoesNotUnlinkAndRetryConfirmsDurability(_ point: InvocationPersistencePoint) async throws {
        let fault = RetentionIOFault()
        var options = AIUsageStorageDependencies(); options.removeEntry = { try fault.unlink($0, $1) }
        try await withBudgetRetentionFixture(options, fault: fault) { fixture in
            let owner = try await seedRetentionBudget(fixture)
            let file = try putRetentionRecord(fixture, owner.id, at: Date().addingTimeInterval(-91 * 86_400))
            let bytes = try Data(contentsOf: file)
            fault.arm(point)
            let failed = await fixture.store.usageMetadataStore.maintain()
            #expect(!failed.isComplete && failed.failedIDs == [owner.id] && failed.removedIDs.isEmpty && fault.unlinks == 0)
            #expect(try Data(contentsOf: file) == bytes)
            let retried = await fixture.store.usageMetadataStore.maintain()
            #expect(retried.isComplete && retried.removedIDs == [owner.id] && fault.unlinks == 1)
            let row = try #require(await fixture.store.aiInvocationStore.list().first { $0.id == owner.id })
            #expect(row.runTokenBudget?.knownTokens == nil && row.runTokenBudget?.maximumTokens == 100)
        }
    }

    @Test(arguments: [false, true])
    func unlinkAndDirectorySyncFailuresRemainPartialUntilRetried(_ directorySync: Bool) async throws {
        let fault = RetentionIOFault()
        var options = AIUsageStorageDependencies()
        options.removeEntry = { try fault.unlink($0, $1) }; options.syncDirectory = { try fault.sync($0) }
        try await withBudgetRetentionFixture(options) { fixture in
            let owner = try await seedRetentionBudget(fixture)
            let file = try putRetentionRecord(fixture, owner.id, at: Date().addingTimeInterval(-91 * 86_400))
            if directorySync { fault.armSync() } else { fault.armUnlink() }
            let failed = await fixture.store.usageMetadataStore.maintain()
            #expect(!failed.isComplete && failed.removedIDs.isEmpty && failed.budgetRedactedIDs == [owner.id])
            #expect(FileManager.default.fileExists(atPath: file.path) != directorySync)
            if directorySync { #expect(failed.uncertainRemovedIDs == [owner.id] && failed.remainingCount == 0) }
            let row = try #require(await fixture.store.aiInvocationStore.list().first { $0.id == owner.id })
            #expect(row.runTokenBudget?.knownTokens == nil)
            let retried = await fixture.store.usageMetadataStore.maintain()
            #expect(retried.isComplete && retried.removedIDs == [owner.id] && !FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func delayedProductionReportCannotRestoreOldOrDuringMaintenanceTicket() async throws {
        let pause = RetentionPause(), id = UUID()
        var options = AIUsageStorageDependencies()
        options.beforeReport = { report in if report.removedIDs.contains(id) { await pause.waitIfArmed() } }
        try await withBudgetRetentionFixture(options) { fixture in
            let owner = try await seedRetentionBudget(fixture, id: id), store = fixture.store
            let old = try #require(await store.aiInvocationStore.list().first { $0.id == owner.id })
            try putRetentionRecord(fixture, id, at: Date().addingTimeInterval(-91 * 86_400))
            let before = store.captureUsageRestoreRead()
            await pause.arm()
            let work = Task { await store.usageMetadataStore.maintain() }
            do {
                try await fixture.eventually { await pause.entered }
                let during = store.captureUsageRestoreRead()
                for ticket in [before, during] {
                    store.tasks.removeAll { $0.id == id }
                    store.restoreHistorySnapshot(cli: [], ai: [old], generation: store.historyGeneration, usageRead: ticket)
                    #expect(store.tasks.first { $0.id == id }?.runTokenBudget?.knownTokens == nil)
                    store.applyRestoredAIUsage(.init(state: .reported, reportedInputTokens: 20, reportedOutputTokens: 11), id: id,
                        historyGeneration: store.historyGeneration, usageGeneration: store.usageHistoryGeneration, usageRead: ticket)
                    #expect(store.tasks.first { $0.id == id }?.aiUsageSummary == .unknown)
                }
                await pause.release(); _ = await work.value
                #expect(!store.acceptsUsageRestoreRead(before) && !store.acceptsUsageRestoreRead(during))
                #expect(store.acceptsUsageRestoreRead(store.captureUsageRestoreRead()))
            } catch { await pause.release(); _ = await work.value; throw error }
        }
    }

    @Test(arguments: [false, true])
    func changedCandidateIsPreservedAfterCoreWait(_ replacingInode: Bool) async throws {
        let pause = RetentionPause(), id = UUID()
        var options = AIUsageStorageDependencies()
        options.beforePrepare = { ids, _ in if ids.contains(id) { await pause.waitIfArmed() } }
        try await withBudgetRetentionFixture(options) { fixture in
            _ = try await seedRetentionBudget(fixture, id: id)
            let file = try putRetentionRecord(fixture, id, at: Date().addingTimeInterval(-91 * 86_400))
            await pause.arm()
            let work = Task { await fixture.store.usageMetadataStore.maintain() }
            do {
                try await fixture.eventually { await pause.entered }
                let fresh = try retentionRecord(id, at: Date())
                try fresh.write(to: file, options: replacingInode ? .atomic : [])
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
                await pause.release(); let report = await work.value
                #expect(!report.isComplete && report.removedIDs.isEmpty && report.problems.contains(.changedCandidate(id)))
                #expect(try Data(contentsOf: file) == fresh)
            } catch { await pause.release(); _ = await work.value; throw error }
        }
    }

    @Test func clearDoesNotClaimSuccessForTerminalLiveOrphanAndReleaseRetriesBudget() async throws {
        try await withBudgetRetentionFixture { fixture in
            let owner = try await seedRetentionBudget(fixture, release: false), store = fixture.store
            let original = try #require(await store.aiInvocationStore.list().first { $0.id == owner.id })
            // Core相位夹具没有真实worker先插入UI行；移除启动可能读到的中途0预算。
            store.tasks.removeAll { $0.id == owner.id }
            store.restoreAIReceipt(original, usageRead: store.captureUsageRestoreRead())
            #expect(store.tasks.first { $0.id == owner.id }?.runTokenBudget?.knownTokens == 31)
            await store.clearAIUsageHistory()
            #expect(store.tasks.first { $0.id == owner.id }?.runTokenBudget?.knownTokens == 31)
            #expect(!store.settingsNotice.isEmpty)
            store.executionReservations.insert(owner.id)
            store.finishExecutionReservation(owner.id, owner: owner)
            try await fixture.eventually { await store.aiInvocationStore.list().first { $0.id == owner.id }?.runTokenBudget?.knownTokens == nil }
            try await fixture.eventually { store.tasks.first { $0.id == owner.id }?.runTokenBudget?.knownTokens == nil }
            let final = try #require(await store.aiInvocationStore.list().first { $0.id == owner.id })
            #expect(final.runAttempt == original.runAttempt && final.runTokenBudget?.maximumTokens == 100)
        }
    }

    @Test func stopWhileStartupReportWaitsCannotRestartTimerAndCloseRejectsLateWrites() async throws {
        let pause = RetentionPause(), reports = RetentionReportCounter()
        try await withBudgetRetentionFixture { fixture in
            let directory = fixture.directory.appendingPathComponent("isolated-timer")
            let metadata = AIUsageMetadataStore(directory: directory, dailyInterval: .milliseconds(15), reportHandler: { report in
                if report.trigger == .startup { await pause.waitIfArmed() }
                await reports.record(report)
            })
            await pause.arm()
            let starting = Task { await metadata.start() }
            do {
                try await fixture.eventually { await pause.entered }
                await metadata.stop(); await pause.release(); _ = await starting.value
                #expect(await metadata.isMaintenanceScheduled == false)
                try await Task.sleep(for: .milliseconds(80))
                #expect(await reports.daily == 0)
                _ = await metadata.start()
                try await fixture.eventually { await reports.daily > 0 }
                await metadata.close()
                #expect(await metadata.isMaintenanceScheduled == false)
                let id = UUID(), rejected = await metadata.save(id: id, data: try retentionRecord(id, at: Date()))
                #expect(!rejected.stored && rejected.report.problems.contains(.storeClosed))
                #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".json").path))
            } catch { await pause.release(); _ = await starting.value; await metadata.close(); throw error }
        }
    }
}

private actor RetentionReportCounter {
    private(set) var daily = 0
    func record(_ report: AIUsageMaintenanceReport) { if report.trigger == .daily { daily += 1 } }
}
