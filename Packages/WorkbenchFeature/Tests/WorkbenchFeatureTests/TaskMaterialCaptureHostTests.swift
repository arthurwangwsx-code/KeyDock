import Foundation
import Dispatch
import Testing
import AutomationCore
import ExecutionCore
@testable import WorkbenchFeature

private final class MaterialBeginPause: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var waiting = false
    private var consumed = false
    private var armed = false
    private var timedOut = false
    var isWaiting: Bool { lock.withLock { waiting } }
    var hasTimedOut: Bool { lock.withLock { timedOut } }
    func arm() { lock.withLock { armed = true } }
    func hook(_ namespace: String, _ point: InvocationPersistencePoint) -> Int32? {
        let pause = lock.withLock {
            guard armed, namespace == "ai", point == .beforeWrite, !consumed else { return false }
            consumed = true; waiting = true; return true
        }
        if pause {
            let result = resume.wait(timeout: .now() + 5)
            lock.withLock { timedOut = result == .timedOut; waiting = false }
        }
        return nil
    }
    func release() { resume.signal() }
}

@Suite(.serialized) @MainActor struct TaskMaterialCaptureHostTests {
    @Test func legacyConfigurationDefaultsOffAndOnlyThePreferenceIsEncoded() throws {
        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: Data("{}".utf8))
        #expect(!legacy.taskMaterialRetentionEnabled)
        var enabled = legacy; enabled.taskMaterialRetentionEnabled = true
        let bytes = try JSONEncoder().encode(enabled)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: bytes)
        #expect(decoded.taskMaterialRetentionEnabled)
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["taskMaterialRetentionEnabled"] as? Bool == true)
        #expect(object["taskMaterialCaptures"] == nil && object["successfulCheckpoint"] == nil)
    }

    @Test func futureWorkflowCapturesFrozenInputAndOnlySuccessfulBoundaryThroughProductionHost() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store
            let definition = WorkflowDefinition(name: "Synthetic retained workflow", steps: [.init(operation: .manualInput)])
            store.configuration.workflows = [definition]
            let prior = try #require(store.runWorkflow(definition, input: "before enabling"))
            try await fixture.eventually { store.pendingWorkflowInputs.contains { $0.runID == prior } }
            #expect(store.taskMaterialCaptures.isEmpty)
            #expect(store.setTaskMaterialRetention(true))
            let oldRequest = try #require(store.pendingWorkflowInputs.first { $0.runID == prior })
            store.resolveWorkflowInput(oldRequest.id, value: "earlier output"); try await fixture.drain(prior)
            #expect(store.taskMaterialCaptures[prior] == nil)
            let exact = "e\u{301}\n synthetic original"
            let run = try #require(store.runWorkflow(definition, input: exact))
            try await fixture.eventually { store.pendingWorkflowInputs.contains { $0.runID == run } }
            let capture = try #require(store.taskMaterialCaptures[run])
            let snapshot = try #require(capture.snapshot()), task = try fixture.task(run)
            #expect(snapshot.input?.utf8.elementsEqual(exact.utf8) == true)
            #expect(snapshot.key.receiptRecordIdentity == task.runAttempt?.recordIdentity)
            if let draftID = task.draftID { store.drafts[draftID]?.editInput("subsequent draft edit") }
            let request = try #require(store.pendingWorkflowInputs.first { $0.runID == run })
            store.resolveWorkflowInput(request.id, value: "confirmed synthetic output"); try await fixture.drain(run)
            let completed = try #require(capture.snapshot())
            #expect(completed.input?.utf8.elementsEqual(exact.utf8) == true)
            #expect(completed.successfulCheckpoint?.input.utf8.elementsEqual(exact.utf8) == true)
            #expect(completed.successfulCheckpoint?.output == "confirmed synthetic output")
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("task-materials").path))
        }
    }

    @Test func failedDisableStaysOffAcrossUnrelatedConfigurationEffectsAndOldWorkerCompletion() async throws {
        let fixture = try WorkflowIntegrationFixture(configurationWriter: { _, _ in throw CocoaError(.fileWriteUnknown) })
        await fixture.stopAutomaticWork()
        do {
            let store = fixture.store
            store.configuration.taskMaterialRetentionEnabled = true; store.applyConfigurationEffects()
            let definition = WorkflowDefinition(name: "Synthetic disable in flight", steps: [.init(operation: .manualInput)])
            store.configuration.workflows = [definition]
            let run = try #require(store.runWorkflow(definition, input: "synthetic input"))
            try await fixture.eventually { store.pendingWorkflowInputs.contains { $0.runID == run } }
            let capture = try #require(store.taskMaterialCaptures[run])
            #expect(capture.snapshot() != nil)
            #expect(!store.setTaskMaterialRetention(false))
            #expect(store.taskMaterialPauseNeedsPersistence && !store.taskMaterialFence.current.enabled)
            #expect(store.taskMaterialCaptures.isEmpty && capture.budgetedBytes == 0)
            store.configuration.taskMaterialRetentionEnabled = true; store.applyConfigurationEffects()
            #expect(!store.taskMaterialFence.current.enabled)
            let request = try #require(store.pendingWorkflowInputs.first { $0.runID == run })
            store.resolveWorkflowInput(request.id, value: "late successful output"); try await fixture.drain(run)
            #expect(try fixture.task(run).status == .completed)
            #expect(capture.snapshot() == nil && capture.budgetedBytes == 0)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test func optionalCheckpointBudgetRefusalDoesNotPreventTheRealWorkflowFromCompleting() async throws {
        let fixture = try WorkflowIntegrationFixture(sessionLimits: .init(textBytes: 2 * 1_024 * 1_024))
        await fixture.stopAutomaticWork()
        do {
            let store = fixture.store
            #expect(store.setTaskMaterialRetention(true))
            let definition = WorkflowDefinition(name: "Synthetic bounded optional capture", steps: [.init(operation: .transform(.trim))])
            store.configuration.workflows = [definition]
            let run = try #require(store.runWorkflow(definition, input: " synthetic "))
            #expect(store.taskMaterialCaptures[run] == nil)
            #expect(store.retainedSessionBytes() <= store.sessionLimits.textBytes)
            try await fixture.drain(run)
            let task = try fixture.task(run)
            #expect(task.status == .completed && task.output == "synthetic")
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test func disablingWhileBeginIsPausedCannotBindTheLateWorkerOrChangeItsExecution() async throws {
        let pause = MaterialBeginPause()
        let fixture = try WorkflowIntegrationFixture(invocationPersistenceFault: pause.hook)
        await fixture.stopAutomaticWork()
        do {
            let store = fixture.store
            #expect(store.setTaskMaterialRetention(true))
            let definition = WorkflowDefinition(name: "Synthetic late begin", steps: [.init(operation: .transform(.trim))])
            store.configuration.workflows = [definition]
            #expect(!pause.isWaiting)
            pause.arm()
            let run = try #require(store.runWorkflow(definition, input: " synthetic "))
            let capture = try #require(store.taskMaterialCaptures[run])
            try await fixture.eventually { pause.isWaiting }
            #expect(store.setTaskMaterialRetention(false))
            #expect(capture.snapshot() == nil && capture.budgetedBytes == 0)
            #expect(store.setTaskMaterialRetention(true))
            pause.release(); try await fixture.drain(run)
            let task = try fixture.task(run)
            #expect(task.status == .completed && task.output == "synthetic" && task.runAttempt != nil)
            #expect(store.taskMaterialCaptures[run] == nil && capture.snapshot() == nil)
            #expect(!pause.hasTimedOut)
            await fixture.cleanup()
        } catch { pause.release(); await fixture.cleanup(); throw error }
    }
}
