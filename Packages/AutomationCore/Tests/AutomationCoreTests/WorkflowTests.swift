import Foundation
import Testing
@testable import AutomationCore

private actor WorkflowHostFixture {
    var requests: [WorkflowHostRequest] = []
    var suspended: CheckedContinuation<Void, Never>?
    var didStart = false
    var released = false
    func mark(_ request: WorkflowHostRequest) { requests.append(request); didStart = true }
    func wait() async {
        if released { return }
        await withCheckedContinuation { suspended = $0 }
    }
    func release() { released = true; suspended?.resume(); suspended = nil }
    func count() -> Int { requests.count }
    func started() -> Bool { didStart && suspended != nil }
}
private enum SyntheticWorkflowError: Error { case injected }
@Suite(.serialized) struct WorkflowTests {
    func plan(_ steps: [WorkflowStep], commands: Set<UUID> = [], actions: Set<UUID> = [], limits: WorkflowLimits = .init()) throws -> WorkflowPlan {
        try WorkflowCompiler.compile(WorkflowDefinition(name: "Synthetic workflow", steps: steps), availableCommandIDs: commands, availableAIActionIDs: actions, limits: limits)
    }
    private func started(_ fixture: WorkflowHostFixture) async throws {
        for _ in 0..<1_000 {
            if await fixture.started() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SyntheticWorkflowError.injected
    }
    @Test func compilerRejectsMissingReferencesInvalidOrderAndUnattendedInteraction() throws {
        let missing = UUID()
        #expect(throws: WorkflowCompileError.missingCommand(missing)) { try plan([.init(operation: .savedCommand(missing))]) }
        #expect(throws: WorkflowCompileError.missingAIAction(missing)) { try plan([.init(operation: .aiAction(missing))]) }
        #expect(throws: WorkflowCompileError.previousOutputUnavailable(0)) { try plan([.init(operation: .transform(.trim), input: .previousOutput)]) }
        let definition = WorkflowDefinition(name: "Synthetic manual workflow", steps: [.init(operation: .manualInput)])
        #expect(throws: WorkflowCompileError.interactionNotAllowed(0)) {
            try WorkflowCompiler.compile(definition, availableCommandIDs: [], availableAIActionIDs: [], allowsInteraction: false)
        }
        let duplicate = UUID()
        #expect(throws: WorkflowCompileError.duplicateStepID) { try plan([.init(id: duplicate, operation: .transform(.trim)), .init(id: duplicate, operation: .transform(.trim))]) }
        #expect(throws: WorkflowCompileError.invalidLimits) { try plan([.init(operation: .transform(.trim))], limits: .init(wallTimeout: .nan)) }
    }
    @Test func frozenPlanRunsTypedBindingsAndMetadataOnlyCheckpoints() async throws {
        let command = UUID(), action = UUID()
        var definition = WorkflowDefinition(name: "Synthetic original", steps: [
            .init(operation: .transform(.trim)), .init(operation: .transform(.uppercase), input: .previousOutput),
            .init(operation: .savedCommand(command), input: .previousOutput), .init(operation: .aiAction(action), input: .previousOutput)
        ])
        let compiled = try WorkflowCompiler.compile(definition, availableCommandIDs: [command], availableAIActionIDs: [action])
        definition.name = "Changed after compile"; definition.steps = []
        let fixture = WorkflowHostFixture()
        let run = await WorkflowRunner.run(compiled, input: "  synthetic-private-input  ") { request in
            await fixture.mark(request)
            switch request.operation {
            case .savedCommand(let id):
                #expect(id == command && request.input == "SYNTHETIC-PRIVATE-INPUT")
                return .init(outcome: .succeeded, output: "synthetic-private-output")
            case .aiAction(let id):
                #expect(id == action && request.input == "synthetic-private-output")
                return .init(outcome: .succeeded, output: "Synthetic summary")
            default: Issue.record("Transforms must stay in Core"); return .init(outcome: .failed)
            }
        }
        #expect(compiled.definition.name == "Synthetic original" && run.outcome == .succeeded && run.completedSteps == 4)
        #expect(run.output == "Synthetic summary" && run.checkpoints.count == 8)
        #expect(run.checkpoints.map(\.sequence) == Array(0..<8))
        #expect(await fixture.count() == 2)
        let metadata = try String(decoding: JSONEncoder().encode(run.checkpoints), as: UTF8.self)
        #expect(!metadata.contains("synthetic-private") && !metadata.contains("SYNTHETIC-PRIVATE"))
    }
    @Test func hostFailureAndUnknownStopWithoutRetryOrNextDispatch() async throws {
        let command = UUID()
        let compiled = try plan([.init(operation: .savedCommand(command)), .init(operation: .savedCommand(command), input: .previousOutput)], commands: [command])
        for outcome in [WorkflowHostOutcome.failed, .unknown] {
            let fixture = WorkflowHostFixture()
            let result = await WorkflowRunner.run(compiled, input: "Synthetic") { request in
                await fixture.mark(request); return .init(outcome: outcome, output: "Synthetic partial")
            }
            #expect(await fixture.count() == 1 && result.completedSteps == 0 && result.stoppedAtStepIndex == 0)
            #expect(result.outcome == (outcome == .failed ? .failed : .unknown))
            #expect(result.hasUncertainHostOutcome == (outcome == .unknown))
            #expect(result.output == "Synthetic partial")
        }
    }
    @Test func thrownHostCannotBeClassifiedAsKnownSafeToReplay() async throws {
        let command = UUID()
        let compiled = try plan([.init(operation: .savedCommand(command))], commands: [command])
        let result = await WorkflowRunner.run(compiled, input: "Synthetic") { _ in throw SyntheticWorkflowError.injected }
        #expect(result.outcome == .unknown && result.reason == .hostThrew && result.hasUncertainHostOutcome)
    }
    @Test func cancellationDropsLateHostResultAndDoesNotDispatchNextStep() async throws {
        let command = UUID()
        let compiled = try plan([.init(operation: .savedCommand(command)), .init(operation: .savedCommand(command))], commands: [command])
        let fixture = WorkflowHostFixture()
        let task = Task {
            await WorkflowRunner.run(compiled, input: "Synthetic") { request in
                await fixture.mark(request); await fixture.wait()
                return .init(outcome: .succeeded, output: "Synthetic late result")
            }
        }
        try await started(fixture); task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled && result.hasUncertainHostOutcome && result.completedSteps == 0)
        #expect(result.output.isEmpty && result.checkpoints.last?.phase == .unknown)
        await fixture.release(); try await Task.sleep(for: .milliseconds(10))
        #expect(await fixture.count() == 1)
    }
    @Test func deadlineReturnsUnknownHostStatusWithoutWaitingForUncooperativeClosure() async throws {
        let command = UUID()
        let compiled = try plan([.init(operation: .savedCommand(command)), .init(operation: .savedCommand(command))], commands: [command], limits: .init(wallTimeout: 0.05))
        let fixture = WorkflowHostFixture(), clock = ContinuousClock()
        let began = clock.now
        let result = await WorkflowRunner.run(compiled, input: "Synthetic") { request in
            await fixture.mark(request); await fixture.wait()
            return .init(outcome: .succeeded, output: "Synthetic late result")
        }
        #expect(clock.now - began < .seconds(2))
        #expect(result.outcome == .timedOut && result.reason == .wallTimeout && result.hasUncertainHostOutcome)
        await fixture.release(); try await Task.sleep(for: .milliseconds(10))
        #expect(await fixture.count() <= 1)
    }
    @Test func outputBudgetIsCumulativeAndUnicodeSafe() async throws {
        let compiled = try plan([.init(operation: .transform(.uppercase), input: .literal("ß")), .init(operation: .transform(.trim), input: .previousOutput)], limits: .init(maxOutputBytes: 3))
        let result = await WorkflowRunner.run(compiled, input: "") { _ in Issue.record("No host operation expected"); return .init(outcome: .failed) }
        #expect(result.outcome == .failed && result.reason == .outputLimit && result.completedSteps == 1)
        #expect(result.output == "S" && result.checkpoints.last?.totalOutputBytes == 3)
        let action = UUID()
        let unicode = try plan([.init(operation: .aiAction(action))], actions: [action], limits: .init(maxOutputBytes: 2))
        let clipped = await WorkflowRunner.run(unicode, input: "Synthetic") { _ in .init(outcome: .succeeded, output: "你") }
        #expect(clipped.outcome == .failed && clipped.output.isEmpty && clipped.reason == .outputLimit)
    }
    @Test func oversizedRuntimeInputNeverCallsTheHost() async throws {
        let command = UUID()
        let compiled = try plan([.init(operation: .savedCommand(command))], commands: [command], limits: .init(maxInputBytes: 1))
        let fixture = WorkflowHostFixture()
        let result = await WorkflowRunner.run(compiled, input: "é") { request in await fixture.mark(request); return .init(outcome: .succeeded) }
        #expect(result.outcome == .failed && result.reason == .inputLimit && result.checkpoints.isEmpty)
        #expect(await fixture.count() == 0)
    }
    @Test func literalTextIsDataAndManualInputRemainsHostControlled() async throws {
        let compiled = try plan([.init(operation: .manualInput, input: .literal("$(never-execute)")), .init(operation: .transform(.lowercase), input: .previousOutput)])
        let result = await WorkflowRunner.run(compiled, input: "") { request in
            #expect(request.operation == .manualInput && request.allowsInteraction && request.input == "$(never-execute)")
            return .init(outcome: .succeeded, output: "SYNTHETIC ANSWER")
        }
        #expect(result.outcome == .succeeded && result.output == "synthetic answer")
    }
}
