import Foundation
import Testing
@testable import AutomationCore

private final class SuccessfulMaterialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WorkflowSuccessfulMaterial] = []
    private var checkpoints: [WorkflowCheckpoint] = []
    private var calls = 0
    func append(_ value: WorkflowSuccessfulMaterial) { lock.withLock { stored.append(value) } }
    func checkpoint(_ value: WorkflowCheckpoint) { lock.withLock { checkpoints.append(value) } }
    func called() { lock.withLock { calls += 1 } }
    var materials: [WorkflowSuccessfulMaterial] { lock.withLock { stored } }
    var metadata: [WorkflowCheckpoint] { lock.withLock { checkpoints } }
    var callCount: Int { lock.withLock { calls } }
}

struct WorkflowSuccessfulMaterialTests {
    private func plan(_ steps: [WorkflowStep], command: UUID? = nil, limits: WorkflowLimits = .init()) throws -> WorkflowPlan {
        try WorkflowCompiler.compile(.init(name: "Synthetic successful boundary", steps: steps),
            availableCommandIDs: command.map { [$0] } ?? [], availableAIActionIDs: [], limits: limits)
    }

    @Test(arguments: [WorkflowHostOutcome.failed, .cancelled, .unknown])
    func unsuccessfulLastOutputCannotBecomeSuccessfulMaterial(outcome: WorkflowHostOutcome) async throws {
        let command = UUID(), run = UUID(), log = SuccessfulMaterialLog()
        let definition = try plan([.init(operation: .transform(.trim)), .init(operation: .savedCommand(command), input: .previousOutput)], command: command)
        let original = " \te\u{301}\n"
        let result = await WorkflowRunner.run(definition, input: original, runID: run,
            host: { _ in .init(outcome: outcome, output: "synthetic unsuccessful result") },
            materialObservation: .init(log.append), onCheckpoint: log.checkpoint)
        #expect(result.completedSteps == 1 && result.output == "synthetic unsuccessful result")
        let values = log.materials
        #expect(values.count == 1)
        let first = try #require(values.first)
        #expect(first.runID == run && first.definitionID == definition.definition.id)
        #expect(first.definitionVersion == definition.definition.version && first.stepID == definition.definition.steps[0].id)
        #expect(first.input.utf8.elementsEqual(original.utf8) && first.output.utf8.elementsEqual("e\u{301}".utf8))
        #expect(first.sequence == 1 && first.stepIndex == 0)
    }

    @Test func overBudgetSuccessDoesNotPublishTruncatedCheckpointMaterial() async throws {
        let command = UUID(), log = SuccessfulMaterialLog()
        let definition = try plan([.init(operation: .transform(.trim)), .init(operation: .savedCommand(command), input: .previousOutput)], command: command,
            limits: .init(maxOutputBytes: 2))
        let result = await WorkflowRunner.run(definition, input: "a", host: { _ in .init(outcome: .succeeded, output: "too long") }, materialObservation: .init(log.append))
        #expect(result.outcome == .failed && result.reason == .outputLimit)
        #expect(log.materials.count == 1 && log.materials.first?.output == "a")
    }

    @Test func firstFailureHasNoSuccessfulMaterial() async throws {
        let command = UUID(), log = SuccessfulMaterialLog()
        let definition = try plan([.init(operation: .savedCommand(command))], command: command)
        let result = await WorkflowRunner.run(definition, input: "input", host: { _ in .init(outcome: .failed, output: "failed") }, materialObservation: .init(log.append))
        #expect(result.outcome == .failed && log.materials.isEmpty)
    }

    @Test func successfulMaterialObserverCancellationStopsTheNextHostDispatch() async throws {
        let command = UUID(), log = SuccessfulMaterialLog()
        let definition = try plan([.init(operation: .transform(.trim)), .init(operation: .savedCommand(command), input: .previousOutput)], command: command)
        let task = Task {
            await WorkflowRunner.run(definition, input: " a ", host: { _ in log.called(); return .init(outcome: .succeeded) },
                materialObservation: .init { value in log.append(value); withUnsafeCurrentTask { $0?.cancel() } })
        }
        let result = await task.value
        #expect(result.outcome == .cancelled && result.completedSteps == 1)
        #expect(log.materials.count == 1 && log.callCount == 0)
    }

    @Test func existingTrailingClosureStillReceivesOnlyMetadata() async throws {
        let log = SuccessfulMaterialLog()
        let definition = try plan([.init(operation: .transform(.trim))])
        let result = await WorkflowRunner.run(definition, input: " x ", host: { _ in .init(outcome: .failed) }) { log.checkpoint($0) }
        #expect(result.outcome == .succeeded && log.metadata.count == 2)
        #expect(log.metadata.map(\.phase) == [.running, .succeeded] && log.materials.isEmpty)
        let implicitHost = await WorkflowRunner.run(definition, input: " x ") { _ in .init(outcome: .failed) }
        #expect(implicitHost.outcome == .succeeded)
    }
}
