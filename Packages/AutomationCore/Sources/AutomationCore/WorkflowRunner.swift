import Foundation

public enum WorkflowRunner {
    /// observer必须快速、同步地投影metadata。需要切到MainActor时按sequence拒绝迟到投影。
    /// 不提供恢复／自动重试入口；unknown运行需要用户检查，任何新运行都由宿主创建新attempt。
    public static func run(_ plan: WorkflowPlan, input: String, runID: UUID = UUID(),
                           host: @escaping WorkflowHostOperation,
                           materialObservation: WorkflowMaterialObservation? = nil,
                           onCheckpoint: @escaping WorkflowCheckpointObserver = { _ in }) async -> WorkflowRunResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(plan.limits.wallTimeout))
        var checkpoints: [WorkflowCheckpoint] = []
        var output = "", completed = 0, totalBytes = 0
        func checkpoint(_ index: Int, _ phase: WorkflowCheckpointPhase, inputBytes: Int,
                        outputBytes: Int = 0, reason: WorkflowStopReason? = nil) {
            let value = WorkflowCheckpoint(runID: runID, definitionID: plan.definition.id,
                definitionVersion: plan.definition.version, sequence: checkpoints.count,
                stepIndex: index, stepID: plan.definition.steps[index].id, phase: phase,
                inputBytes: inputBytes, outputBytes: outputBytes, totalOutputBytes: totalBytes, reason: reason)
            checkpoints.append(value); onCheckpoint(value)
        }
        func result(_ state: WorkflowRunOutcome, index: Int? = nil,
                    reason: WorkflowStopReason? = nil, uncertain: Bool = false) -> WorkflowRunResult {
            WorkflowRunResult(runID: runID, outcome: state, output: output, completedSteps: completed,
                stoppedAtStepIndex: index, reason: reason, hasUncertainHostOutcome: uncertain, checkpoints: checkpoints)
        }
        guard input.utf8.count <= plan.limits.maxInputBytes else { return result(.failed, reason: .inputLimit) }
        for (index, step) in plan.definition.steps.enumerated() {
            if Task.isCancelled { return result(.cancelled, index: index, reason: .cancelled) }
            if clock.now >= deadline { return result(.timedOut, index: index, reason: .wallTimeout) }
            let stepInput: String
            switch step.input {
            case .workflowInput: stepInput = input
            case .previousOutput: stepInput = output
            case .literal(let value): stepInput = value
            }
            let inputBytes = stepInput.utf8.count
            guard inputBytes <= plan.limits.maxInputBytes else {
                checkpoint(index, .failed, inputBytes: inputBytes, reason: .inputLimit)
                return result(.failed, index: index, reason: .inputLimit)
            }
            checkpoint(index, .running, inputBytes: inputBytes)
            // observer不能成为绕过取消／预算后派发副作用的窗口。
            if Task.isCancelled {
                checkpoint(index, .cancelled, inputBytes: inputBytes, reason: .cancelled)
                return result(.cancelled, index: index, reason: .cancelled)
            }
            if clock.now >= deadline {
                checkpoint(index, .timedOut, inputBytes: inputBytes, reason: .wallTimeout)
                return result(.timedOut, index: index, reason: .wallTimeout)
            }
            let response: WorkflowHostResult
            switch step.operation {
            case .transform(let transform):
                let transformed: String
                switch transform {
                case .trim: transformed = stepInput.trimmingCharacters(in: .whitespacesAndNewlines)
                case .uppercase: transformed = stepInput.uppercased()
                case .lowercase: transformed = stepInput.lowercased()
                }
                response = WorkflowHostResult(outcome: .succeeded, output: transformed)
            default:
                let request = WorkflowHostRequest(runID: runID, definitionID: plan.definition.id,
                    definitionVersion: plan.definition.version, stepID: step.id, stepIndex: index,
                    operation: step.operation, input: stepInput, allowsInteraction: plan.allowsInteraction)
                switch await WorkflowTimedCall.perform(deadline: deadline, host: host, request: request) {
                case .value(let value): response = value
                case .threw:
                    checkpoint(index, .unknown, inputBytes: inputBytes, reason: .hostThrew)
                    return result(.unknown, index: index, reason: .hostThrew, uncertain: true)
                case .cancelled:
                    checkpoint(index, .unknown, inputBytes: inputBytes, reason: .cancelled)
                    return result(.cancelled, index: index, reason: .cancelled, uncertain: true)
                case .timedOut:
                    checkpoint(index, .unknown, inputBytes: inputBytes, reason: .wallTimeout)
                    return result(.timedOut, index: index, reason: .wallTimeout, uncertain: true)
                }
            }
            let bytes = response.output.utf8.count
            let remaining = plan.limits.maxOutputBytes - totalBytes
            guard bytes <= remaining else {
                output = prefix(response.output, maxBytes: remaining); totalBytes += output.utf8.count
                checkpoint(index, .failed, inputBytes: inputBytes, outputBytes: output.utf8.count, reason: .outputLimit)
                return result(.failed, index: index, reason: .outputLimit, uncertain: response.outcome == .unknown)
            }
            output = response.output; totalBytes += bytes
            switch response.outcome {
            case .succeeded:
                completed += 1; checkpoint(index, .succeeded, inputBytes: inputBytes, outputBytes: bytes)
                materialObservation?.observe(.init(runID: runID, definitionID: plan.definition.id,
                    definitionVersion: plan.definition.version, stepID: step.id, stepIndex: index,
                    sequence: checkpoints.count - 1, input: stepInput, output: response.output))
            case .failed:
                checkpoint(index, .failed, inputBytes: inputBytes, outputBytes: bytes, reason: .hostFailed)
                return result(.failed, index: index, reason: .hostFailed)
            case .cancelled:
                checkpoint(index, .cancelled, inputBytes: inputBytes, outputBytes: bytes, reason: .hostCancelled)
                return result(.cancelled, index: index, reason: .hostCancelled)
            case .unknown:
                checkpoint(index, .unknown, inputBytes: inputBytes, outputBytes: bytes, reason: .hostUnknown)
                return result(.unknown, index: index, reason: .hostUnknown, uncertain: true)
            }
        }
        if Task.isCancelled { return result(.cancelled, reason: .cancelled) }
        return result(.succeeded)
    }

    private static func prefix(_ value: String, maxBytes: Int) -> String {
        var bytes = Array(value.utf8.prefix(max(0, maxBytes)))
        while let last = bytes.last, last >= 0x80, String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
