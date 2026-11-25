import Foundation
import Dispatch
import Testing
import AutomationCore
import ExecutionCore
@testable import WorkbenchFeature

private final class MaterialInputGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var armed = false, used = false, waiting = false, timeout = false
    func arm() { lock.withLock { armed = true } }
    var isWaiting: Bool { lock.withLock { waiting } }; var timedOut: Bool { lock.withLock { timeout } }
    func pause() {
        let pause = lock.withLock { if !armed || used { return false }; used = true; waiting = true; return true }
        if pause { let result = semaphore.wait(timeout: .now() + 5); lock.withLock { waiting = false; timeout = result == .timedOut } }
    }
    func release() { semaphore.signal() }
}

@Suite(.serialized) @MainActor struct TaskMaterialInputTests {
    private func prepare(_ fixture: WorkflowIntegrationFixture, input: String = "e\u{301}\nsynthetic original", retainInput: Bool = true) async throws -> AttemptPreparationPresentation {
        let store = fixture.store
        #expect(store.setTaskMaterialRetention(true))
        let definition = WorkflowDefinition(name: "Synthetic reusable input", steps: [.init(operation: .transform(.trim))])
        store.configuration.workflows = [definition]
        let run = try #require(store.runWorkflow(definition, input: input)); try await fixture.drain(run)
        let buffer = try store.freezeTaskMaterialReview(run), material = try #require(buffer.material)
        let selected = retainInput ? SelectedTaskMaterial(input: material.input) : SelectedTaskMaterial(visibleResult: material.visibleResult,
            resultKind: material.resultKind, resultWasPartial: material.resultWasPartial, resultCapturedAt: material.resultCapturedAt)
        _ = try await store.saveTaskMaterial(selected, buffer: buffer, expected: nil)
        store.releaseTaskMaterialBuffer(buffer.id)
        let presentation = AttemptPreparationPresentation(.init(store: .ai, invocationID: run))
        await presentation.refresh(in: store)?.value
        #expect(presentation.phase == .ready)
        return presentation
    }

    @Test func retainedInputFillsAnEmptyPreparationWithoutStartingOrCopyingAnything() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let presentation = try await prepare(fixture), store = fixture.store
            let before = await store.aiInvocationStore.list()
            await presentation.materialInput.load(into: presentation, in: store)?.value
            #expect(presentation.input.utf8.elementsEqual("e\u{301}\nsynthetic original".utf8))
            #expect(presentation.phase == .ready && store.executionReservations.isEmpty && store.taskMaterialBuffers.isEmpty)
            let after = await store.aiInvocationStore.list()
            #expect(after == before)
            presentation.invalidate()
        }
    }

    @Test func nonemptyInputNeedsExplicitReplacementAndDiscardKeepsTheUserText() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let presentation = try await prepare(fixture), store = fixture.store
            presentation.editInput("user current input")
            await presentation.materialInput.load(into: presentation, in: store)?.value
            #expect(presentation.materialInput.replacementReady && presentation.input == "user current input")
            presentation.materialInput.invalidate()
            #expect(presentation.input == "user current input" && store.taskMaterialBuffers.isEmpty)
            await presentation.materialInput.load(into: presentation, in: store)?.value
            await presentation.materialInput.replace(into: presentation, in: store)?.value
            #expect(presentation.input.utf8.elementsEqual("e\u{301}\nsynthetic original".utf8))
            #expect(store.executionReservations.isEmpty && store.taskMaterialBuffers.isEmpty)
            presentation.invalidate()
        }
    }

    @Test func rejectedOversizeEditAndABAInvalidateTheOldReplacementTicket() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let presentation = try await prepare(fixture), store = fixture.store
            presentation.editInput("e\u{301}")
            await presentation.materialInput.load(into: presentation, in: store)?.value
            let revision = presentation.inputRevision
            presentation.editInput(String(repeating: "x", count: TaskTextLimits.inputBytes + 1))
            #expect(presentation.inputRejected && presentation.inputRevision != revision)
            presentation.editInput("é"); presentation.editInput("e\u{301}")
            #expect(presentation.materialInput.replace(into: presentation, in: store) == nil)
            #expect(presentation.input.utf8.elementsEqual("e\u{301}".utf8) && store.taskMaterialBuffers.isEmpty)
            presentation.invalidate()
        }
    }

    @Test func materialVersionChangeCannotReplaceUserInputWithAnOldSnapshot() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let presentation = try await prepare(fixture), store = fixture.store
            presentation.editInput("keep this")
            let handle = try #require(presentation.materialInput.availableHandle(presentation, in: store))
            await presentation.materialInput.load(into: presentation, in: store)?.value
            let check = try await store.taskMaterialStore.prepareWrite(handle.key, expected: handle.version)
            _ = try await store.taskMaterialStore.save(.init(input: "a newer explicit saved input"), using: check)
            await presentation.materialInput.replace(into: presentation, in: store)?.value
            #expect(presentation.input == "keep this" && store.taskMaterialBuffers.isEmpty && store.executionReservations.isEmpty)
            presentation.invalidate()
        }
    }

    @Test func editingDuringTheActualReadRejectsLateFillAndReleasesItsBudget() async throws {
        let gate = MaterialInputGate(), fixture = try WorkflowIntegrationFixture(taskMaterialReadObserver: { kind, _ in if kind == .payload { gate.pause() } })
        await fixture.stopAutomaticWork()
        do {
            let presentation = try await prepare(fixture), store = fixture.store
            gate.arm()
            let loading = try #require(presentation.materialInput.load(into: presentation, in: store))
            try await fixture.eventually { gate.isWaiting }
            presentation.editInput("user edited while reading")
            gate.release(); await loading.value
            #expect(presentation.input == "user edited while reading" && store.taskMaterialBuffers.isEmpty && !gate.timedOut)
            presentation.invalidate(); await fixture.cleanup()
        } catch { gate.release(); await fixture.cleanup(); throw error }
    }

    @Test func resultOnlyMaterialIsNeverUsedAsAnInputFallback() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let presentation = try await prepare(fixture, retainInput: false)
            #expect(presentation.materialInput.availableHandle(presentation, in: fixture.store) == nil)
            #expect(presentation.materialInput.load(into: presentation, in: fixture.store) == nil)
            #expect(presentation.input.isEmpty && fixture.store.executionReservations.isEmpty)
            presentation.invalidate()
        }
    }

    @Test func emptyOriginalInputRemainsAnExactEmptyValueWithRetentionOff() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let presentation = try await prepare(fixture, input: ""), store = fixture.store
            #expect(store.setTaskMaterialRetention(false)); await store.taskMaterialPermissionTask?.value
            // 隐私偏好也推进既有配置审阅代次；保持新尝试的范围检查，不放宽旧票据。
            await presentation.refresh(in: store)?.value
            presentation.editInput("replace me explicitly")
            await presentation.materialInput.load(into: presentation, in: store)?.value
            #expect(presentation.materialInput.replacementReady)
            await presentation.materialInput.replace(into: presentation, in: store)?.value
            #expect(presentation.input.isEmpty && store.executionReservations.isEmpty)
            presentation.invalidate()
        }
    }
}
