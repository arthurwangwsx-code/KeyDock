import Foundation
import Darwin
import Dispatch
import Testing
import AutomationCore
import ExecutionCore
import MacAdapters
@testable import WorkbenchFeature

private final class MaterialHostReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var payloadBytes = 0
    func observe(_ kind: TaskMaterialReadKind, _ count: Int) { if kind == .payload { lock.withLock { payloadBytes += count } } }
    var total: Int { lock.withLock { payloadBytes } }
}
private final class MaterialHostGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false, used = false, waiting = false, timeout = false
    var isWaiting: Bool { lock.withLock { waiting } }
    var timedOut: Bool { lock.withLock { timeout } }
    func arm() { lock.withLock { armed = true } }
    func pause() {
        let shouldWait = lock.withLock { if !armed || used { return false }; used = true; waiting = true; return true }
        if shouldWait {
            let result = semaphore.wait(timeout: .now() + 5)
            lock.withLock { waiting = false; timeout = result == .timedOut }
        }
    }
    func release() { semaphore.signal() }
}
private final class MaterialDeleteFault: @unchecked Sendable {
    private let lock = NSLock(); private var enabled = false
    func set(_ value: Bool) { lock.withLock { enabled = value } }
    func hook(_ role: TaskMaterialWriteRole, _ point: TaskMaterialPersistencePoint, _ name: String) -> Int32? {
        lock.withLock { enabled && role == .body && point == .beforeDelete ? EACCES : nil }
    }
}
@MainActor private final class MaterialHostClipboardSource: ClipboardCaptureSource {
    var changeCount: Int { 0 }; var availableTypes: [String] { [] }; var sourceApplication: String? { nil }
    func readText() -> String? { Issue.record("Unexpected system clipboard access"); return nil }
}

@Suite(.serialized) @MainActor struct TaskMaterialHostTests {
    private func run(_ fixture: WorkflowIntegrationFixture, input: String = " e\u{301} synthetic ") async throws -> UUID {
        let store = fixture.store
        if !store.taskMaterialFence.current.enabled { #expect(store.setTaskMaterialRetention(true)) }
        let definition = WorkflowDefinition(name: "Synthetic material source", steps: [.init(operation: .transform(.trim))])
        store.configuration.workflows.append(definition)
        let id = try #require(store.runWorkflow(definition, input: input)); try await fixture.drain(id)
        return id
    }
    private func save(_ fixture: WorkflowIntegrationFixture, id: UUID) async throws -> TaskMaterialHandle {
        let buffer = try fixture.store.freezeTaskMaterialReview(id)
        defer { fixture.store.releaseTaskMaterialBuffer(buffer.id) }
        let material = try #require(buffer.material)
        return try await fixture.store.saveTaskMaterial(.init(input: material.input), buffer: buffer, expected: nil)
    }

    @Test func libraryDistinguishesPendingFailedAndConfirmedEmptyReads() async throws {
        let gate = MaterialHostGate(), fixture = try WorkflowIntegrationFixture(taskMaterialReadObserver: { kind, _ in if kind == .header { gate.pause() } })
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), handle = try await save(fixture, id: id), store = fixture.store
            gate.arm(); let loading = Task { await store.refreshTaskMaterialIndex() }
            try await fixture.eventually { gate.isWaiting }
            #expect(store.taskMaterialIndexPhase == .loading)
            gate.release(); await loading.value
            #expect(store.taskMaterialIndexPhase == .ready && store.taskMaterialRecords.count == 1 && !gate.timedOut)
            // 真实坏header不能被当作已确认空库；仅破坏本用例创建的合成文件。
            let body = fixture.directory.appendingPathComponent("task-materials").appendingPathComponent(handle.key.fileName)
            try Data("bad synthetic header".utf8).write(to: body, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: body.path)
            await store.refreshTaskMaterialIndex()
            #expect(store.taskMaterialIndexPhase == .failed && store.taskMaterialRecords.isEmpty)
            try FileManager.default.removeItem(at: body)
            await store.refreshTaskMaterialIndex()
            #expect(store.taskMaterialIndexPhase == .ready && store.taskMaterialRecords.isEmpty)
            await fixture.cleanup()
        } catch { gate.release(); await fixture.cleanup(); throw error }
    }

    @Test func disablingCaptureDuringIndexReadReleasesLoadingAndAllowsANewRead() async throws {
        let gate = MaterialHostGate(), fixture = try WorkflowIntegrationFixture(taskMaterialReadObserver: { kind, _ in if kind == .header { gate.pause() } })
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), _ = try await save(fixture, id: id), store = fixture.store
            gate.arm(); let oldRead = Task { await store.refreshTaskMaterialIndex() }
            try await fixture.eventually { gate.isWaiting }
            #expect(store.taskMaterialIndexPhase == .loading)
            #expect(store.setTaskMaterialRetention(false))
            #expect(store.taskMaterialIndexPhase == .idle && !store.taskMaterialFence.current.enabled)
            let newRead = Task { await store.refreshTaskMaterialIndex() }
            try await fixture.eventually { store.taskMaterialIndexPhase == .loading }
            gate.release(); await oldRead.value; await newRead.value
            #expect(store.taskMaterialIndexPhase == .ready && store.taskMaterialRecords.count == 1 && !gate.timedOut)
            await fixture.cleanup()
        } catch { gate.release(); await fixture.cleanup(); throw error }
    }

    @Test func reviewHasNoSelectedFieldsAndSaveViewRestartDoNotAutomaticallyReadOrExecute() async throws {
        let reads = MaterialHostReadLog(), fixture = try WorkflowIntegrationFixture(taskMaterialReadObserver: reads.observe)
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), store = fixture.store, task = try fixture.task(id)
            let key = try #require(store.taskMaterialKey(task))
            let review = TaskMaterialPresentation(key: key, mode: .saveReview, title: "Synthetic", store: store)
            await review.refresh(in: store)?.value
            #expect(review.phase == .ready && review.selectedFields.isEmpty && !review.canSave)
            #expect(try await store.taskMaterialStore.inventory().handles.isEmpty)
            review.selectedFields = [.input]
            await review.save(review.reviewID, in: store)?.value
            #expect(review.phase == .saved && reads.total == 0)
            review.invalidate()
            let index = try await store.taskMaterialStore.inventory(), handle = try #require(index.handles.first)
            #expect(handle.header.fields == [.input] && store.taskMaterialBuffers.isEmpty)
            await store.shutdownAndWait()
            let reopened = try WorkbenchModel(dataDirectory: fixture.directory, allowContextCapture: false,
                clipboardWriter: { _ in Issue.record("Unexpected copy") }, clipboardReader: { Issue.record("Unexpected clipboard read"); return nil },
                credentialReader: { _ in Issue.record("Unexpected API credential lookup"); return nil }, applicationCatalog: ApplicationCatalog(roots: []),
                clipboardCaptureSource: MaterialHostClipboardSource(), taskMaterialReadObserver: reads.observe, languageApplier: { _ in })
            await reopened.maintainTaskMaterials()
            #expect(reads.total == 0 && reopened.taskMaterialHandles[key]?.version == handle.version)
            #expect(reopened.executionReservations.isEmpty && reopened.taskHandles.isEmpty)
            let viewer = TaskMaterialPresentation(key: key, mode: .view, title: "Synthetic retained", store: reopened)
            await viewer.refresh(in: reopened)?.value
            #expect(viewer.phase == .ready && viewer.buffer?.material?.input?.utf8.elementsEqual(" e\u{301} synthetic ".utf8) == true)
            #expect(viewer.buffer?.material?.visibleResult == nil && reads.total > 0)
            viewer.invalidate(); await reopened.shutdownAndWait(); await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test func clearingHistoryKeepsParentMetadataWhenMaterialDeletionIsNotConfirmed() async throws {
        let fault = MaterialDeleteFault(), fixture = try WorkflowIntegrationFixture(taskMaterialPersistenceFault: fault.hook)
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), store = fixture.store
            let handle = try await save(fixture, id: id)
            fault.set(true)
            await store.clearFinishedHistory()
            let retained = await store.aiInvocationStore.list()
            #expect(retained.contains { $0.id == id } && store.tasks.contains { $0.id == id })
            #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("task-materials").appendingPathComponent(handle.key.fileName).path))
            #expect(!store.settingsNotice.isEmpty)
            fault.set(false); await store.clearFinishedHistory()
            let cleared = await store.aiInvocationStore.list()
            #expect(!cleared.contains { $0.id == id })
            #expect(try await store.taskMaterialStore.inventory().handles.isEmpty)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test func deletingAnotherMaterialDoesNotRevokeTheRunningCapture() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let first = try await run(fixture), handle = try await save(fixture, id: first), store = fixture.store
            let definition = WorkflowDefinition(name: "Synthetic running capture", steps: [.init(operation: .manualInput)])
            store.configuration.workflows.append(definition)
            let second = try #require(store.runWorkflow(definition, input: "second exact input"))
            try await fixture.eventually { store.pendingWorkflowInputs.contains { $0.runID == second } }
            let capture = try #require(store.taskMaterialCaptures[second])
            #expect(await store.deleteTaskMaterial(handle).isComplete)
            #expect(capture.snapshot()?.input == "second exact input")
            let request = try #require(store.pendingWorkflowInputs.first { $0.runID == second })
            store.resolveWorkflowInput(request.id, value: "second confirmed output"); try await fixture.drain(second)
            #expect(capture.snapshot()?.successfulCheckpoint?.output == "second confirmed output")
        }
    }

    @Test func closedSaveReviewKeepsItsWorkerBudgetUntilTheRealWriteFinishes() async throws {
        let gate = MaterialHostGate(), fixture = try WorkflowIntegrationFixture(taskMaterialPersistenceFault: { role, point, _ in
            if role == .body, point == .beforeRename { gate.pause() }; return nil
        })
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), store = fixture.store, buffer = try store.freezeTaskMaterialReview(id)
            let selected = SelectedTaskMaterial(input: try #require(buffer.material?.input))
            gate.arm()
            let worker = try store.startTaskMaterialSave(selected, buffer: buffer, expected: nil)
            try await fixture.eventually { gate.isWaiting }
            #expect(throws: TaskMaterialError.staleCheck) { try store.startTaskMaterialSave(selected, buffer: buffer, expected: nil) }
            store.releaseTaskMaterialBuffer(buffer.id)
            #expect(buffer.material == nil && store.taskMaterialWriteReservations.values.reduce(0, +) == selected.rawBytes)
            gate.release(); _ = try await worker.value
            #expect(store.taskMaterialWriteReservations.isEmpty && !gate.timedOut)
            await fixture.cleanup()
        } catch { gate.release(); await fixture.cleanup(); throw error }
    }

    @Test func clearingDuringBodyReadKeepsDecodeBudgetAndRejectsTheLateResult() async throws {
        let gate = MaterialHostGate(), fixture = try WorkflowIntegrationFixture(taskMaterialReadObserver: { kind, _ in if kind == .payload { gate.pause() } })
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), store = fixture.store, handle = try await save(fixture, id: id)
            gate.arm()
            let reading = Task { try? await store.readTaskMaterial(handle) }
            try await fixture.eventually { gate.isWaiting }
            let clearing = Task { await store.clearTaskMaterials() }
            try await fixture.eventually { store.taskMaterialClearing }
            let buffer = try #require(store.taskMaterialBuffers.values.first)
            #expect(buffer.invalidated && buffer.inFlight && buffer.material == nil && buffer.budgetedBytes > 0)
            gate.release()
            let returned = await reading.value; await clearing.value
            #expect(returned == nil && store.taskMaterialBuffers.isEmpty && store.taskMaterialHandles.isEmpty && !gate.timedOut)
            await fixture.cleanup()
        } catch { gate.release(); await fixture.cleanup(); throw error }
    }

    @Test func materialSheetKeepsItsOwnerUntilActualDismissAndBlocksReverseModals() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let id = try await run(fixture), store = fixture.store, session = WorkspaceSession()
            session.setVisible(true, in: store)
            session.prepareTaskMaterial(id, mode: .saveReview, in: store)
            let first = try #require(session.taskMaterialPresentation)
            session.taskMaterialDidAppear(first.id)
            session.prepareAttempt(id, in: store)
            #expect(session.attemptPreparation == nil && session.hasPendingOrDismissingModal)
            session.cancelTaskMaterial(first.id)
            #expect(session.taskMaterialPresentation === first && session.taskMaterialDismissing)
            session.prepareTaskMaterial(id, mode: .saveReview, in: store)
            #expect(session.taskMaterialPresentation === first)
            session.taskMaterialDidDismiss(first.id)
            session.prepareTaskMaterial(id, mode: .saveReview, in: store)
            let second = try #require(session.taskMaterialPresentation)
            #expect(second.id != first.id)
            session.taskMaterialDidDismiss(first.id)
            #expect(session.taskMaterialPresentation === second)
            session.invalidateTaskMaterialPresentation()
        }
    }

    @Test func generationChangeDuringHeaderLoadEndsTheOldReadingState() async throws {
        let gate = MaterialHostGate(), fixture = try WorkflowIntegrationFixture(taskMaterialReadObserver: { kind, _ in if kind == .header { gate.pause() } })
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), handle = try await save(fixture, id: id), store = fixture.store
            let viewer = TaskMaterialPresentation(key: handle.key, mode: .view, title: "Synthetic changed generation", store: store)
            gate.arm(); let loading = try #require(viewer.refresh(in: store))
            try await fixture.eventually { gate.isWaiting }
            store.taskMaterialOwnersWereRemoved()
            gate.release(); await loading.value
            #expect(viewer.phase == .unavailable && !viewer.isReading && !gate.timedOut)
            #expect(store.taskMaterialBuffers.isEmpty)
            viewer.invalidate(); await fixture.cleanup()
        } catch { gate.release(); await fixture.cleanup(); throw error }
    }

    @Test func aSaveWaitingForItsFinalOwnerQueryCannotRepublishAHandleAfterClear() async throws {
        let body = MaterialHostGate(), metadata = MaterialHostGate()
        let fixture = try WorkflowIntegrationFixture(taskMaterialPersistenceFault: { role, point, _ in
            if role == .body, point == .beforeRename { body.pause() }; return nil
        }, invocationPersistenceFault: { namespace, point in
            if namespace == "ai", point == .beforeWrite { metadata.pause() }; return nil
        })
        await fixture.stopAutomaticWork()
        do {
            let id = try await run(fixture), store = fixture.store, buffer = try store.freezeTaskMaterialReview(id)
            let selected = SelectedTaskMaterial(input: try #require(buffer.material?.input))
            body.arm(); let saving = try store.startTaskMaterialSave(selected, buffer: buffer, expected: nil)
            try await fixture.eventually { body.isWaiting }
            metadata.arm()
            let definition = try #require(store.configuration.workflows.first)
            let other = try #require(store.runWorkflow(definition, input: "another synthetic run"))
            try await fixture.eventually { metadata.isWaiting }
            body.release()
            try await fixture.eventually { try await store.taskMaterialStore.inventory().handles.count == 1 }
            await store.clearTaskMaterials()
            #expect(store.taskMaterialHandles.isEmpty)
            metadata.release(); _ = try await saving.value; try await fixture.drain(other)
            #expect(store.taskMaterialHandles.isEmpty && store.taskMaterialWriteReservations.isEmpty)
            #expect(try await store.taskMaterialStore.inventory().handles.isEmpty)
            #expect(!body.timedOut && !metadata.timedOut)
            await fixture.cleanup()
        } catch { body.release(); metadata.release(); await fixture.cleanup(); throw error }
    }

    @Test func savedContentAndNewAttemptRemainAvailableAfterTheMemoryTaskIsEvicted() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let id = try await run(fixture), store = fixture.store, handle = try await save(fixture, id: id)
            store.removeSessionObjects(tasks: [id], drafts: [])
            #expect(!store.tasks.contains { $0.id == id })
            await store.refreshTaskMaterialIndex()
            let record = try #require(store.taskMaterialRecords.first { $0.id == handle.key })
            let session = WorkspaceSession()
            session.prepareRetainedTaskMaterial(record, in: store)
            let viewer = try #require(session.taskMaterialPresentation)
            await viewer.refresh(in: store)?.value
            #expect(viewer.phase == .ready && viewer.buffer?.material?.input != nil)
            session.invalidateTaskMaterialPresentation()
            session.prepareAttempt(.init(store: .ai, invocationID: id), in: store)
            let attempt = try #require(session.attemptPreparation)
            await attempt.refresh(in: store)?.value
            #expect(attempt.phase == .ready && store.executionReservations.isEmpty)
            session.invalidateAttemptPreparation()
        }
    }
}
