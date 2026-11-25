import Foundation
import Testing
import ExecutionCore
@testable import AutomationCore
@testable import WorkbenchFeature

struct TaskMaterialCaptureTests {
    private func definition(_ kind: RecoverableRunKind = .workflow) -> RunDefinitionReference {
        .init(kind: kind, definitionID: UUID(), definitionVersion: 1, fingerprint: String(repeating: "a", count: 64))
    }
    private func bound(_ fence: TaskMaterialFence, input: String = "synthetic", definition: RunDefinitionReference? = nil) async throws -> TaskMaterialCapture {
        let root = try TaskMaterialTestFixtures.directory("Capture"); defer { try? FileManager.default.removeItem(at: root) }
        let reference = definition ?? self.definition(), id = UUID()
        let capture = try #require(TaskMaterialCapture(runID: id, definition: reference, input: input, fence: fence))
        let store = try InvocationStore(directory: root)
        let begun = try await store.begin(id: id, name: "Synthetic capture", runDefinition: reference)
        capture.bind(begun, namespace: .ai)
        #expect(capture.snapshot()?.key.receiptRecordIdentity == begun.runStamp?.recordIdentity)
        return capture
    }
    private func material(_ capture: TaskMaterialCapture, sequence: Int, input: String = "step input", output: String = "step output", runID: UUID? = nil) -> WorkflowSuccessfulMaterial {
        .init(runID: runID ?? capture.runID, definitionID: capture.definition.definitionID,
              definitionVersion: 1, stepID: UUID(), stepIndex: sequence / 2, sequence: sequence, input: input, output: output)
    }

    @Test func disabledPermissionDoesNotCaptureAndEmptyIsAnExactInput() async throws {
        let fence = TaskMaterialFence(), reference = definition()
        #expect(TaskMaterialCapture(runID: UUID(), definition: reference, input: "synthetic", fence: fence) == nil)
        fence.setEnabled(true)
        let empty = try await bound(fence, input: "")
        #expect(empty.snapshot()?.input == "" && empty.capturedInputBytes == 0)
        let exact = "e\u{301}\n\t synthetic"
        let capture = try await bound(fence, input: exact)
        #expect(capture.snapshot()?.input?.utf8.elementsEqual(exact.utf8) == true)
        #expect(TaskMaterialCapture(runID: UUID(), definition: definition(.savedCommand), input: "argv must not be captured", fence: fence) == nil)
        #expect(TaskMaterialCapture(runID: UUID(), definition: reference, input: nil, fence: fence) == nil)
    }

    @Test func permissionABAAndExplicitClearCannotReviveOldCapture() async throws {
        let fence = TaskMaterialFence(); fence.setEnabled(true)
        let capture = try await bound(fence)
        capture.observe(material(capture, sequence: 1))
        fence.setEnabled(false); fence.setEnabled(true)
        capture.observe(material(capture, sequence: 3))
        #expect(capture.snapshot() == nil)
        capture.revoke()
        #expect(capture.budgetedBytes == 0 && capture.capturedInputBytes == 0)
        let next = try await bound(fence)
        fence.invalidateContent()
        #expect(next.snapshot() == nil)
    }

    @Test func latestSuccessfulBoundaryUsesSequenceAndNeverFallsBackAfterOversizedSuccess() async throws {
        let fence = TaskMaterialFence(); fence.setEnabled(true)
        let capture = try await bound(fence)
        capture.observe(material(capture, sequence: 3, output: "new"))
        capture.observe(material(capture, sequence: 1, output: "old"))
        capture.observe(material(capture, sequence: 5, output: "foreign", runID: UUID()))
        #expect(capture.snapshot()?.successfulCheckpoint?.output == "new")
        capture.observe(material(capture, sequence: 5, output: String(repeating: "x", count: TaskMaterialLimits.outputBytes + 1)))
        capture.observe(material(capture, sequence: 3, output: "must not return"))
        #expect(capture.snapshot()?.successfulCheckpoint == nil && capture.snapshot()?.latestBoundaryExceededLimit == true)
        capture.observe(material(capture, sequence: 7, output: "later bounded success"))
        capture.finish()
        capture.observe(material(capture, sequence: 9, output: "too late"))
        #expect(capture.snapshot()?.successfulCheckpoint?.output == "later bounded success")
    }

    @Test func synchronousConcurrentObserversKeepTheHighestSequenceAndPreallocatedBudget() async throws {
        let fence = TaskMaterialFence(); fence.setEnabled(true)
        let capture = try await bound(fence, input: "a")
        let reservation = TaskMaterialCapture.checkpointReservation
        #expect(capture.budgetedBytes == reservation + 1)
        await withTaskGroup(of: Void.self) { group in
            for sequence in 0..<100 { let value = material(capture, sequence: sequence); group.addTask { capture.observe(value) } }
        }
        #expect(capture.snapshot()?.successfulCheckpoint?.sequence == 99)
        #expect(capture.budgetedBytes == reservation + 1)
        capture.finish()
        #expect(capture.budgetedBytes == 1 + "step input".utf8.count + "step output".utf8.count)
    }
}
