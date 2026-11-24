import Foundation

private enum WorkflowTimedResult<Value: Sendable>: Sendable {
    case value(Value), failed, cancelled, timedOut
}

/// 只封闭宿主返回值竞态，不声称强制终止不合作的Swift闭包或外部副作用。
/// 超时／取消后不再派发下一步；迟到结果丢弃，宿主依旧负责真实资源收口与unknown回执。
private final class WorkflowHostRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: WorkflowTimedResult<Value>?
    private var continuation: CheckedContinuation<WorkflowTimedResult<Value>, Never>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func perform(deadline: ContinuousClock.Instant, operation: @escaping @Sendable () async throws -> Value) async -> WorkflowTimedResult<Value> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(continuation, deadline: deadline, operation: operation)
            }
        } onCancel: { finish(.cancelled) }
    }
    private func start(_ continuation: CheckedContinuation<WorkflowTimedResult<Value>, Never>,
                       deadline: ContinuousClock.Instant, operation: @escaping @Sendable () async throws -> Value) {
        let prior = lock.withLock { () -> WorkflowTimedResult<Value>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let prior { continuation.resume(returning: prior); return }
        let worker = Task.detached { [self] in
            guard lock.withLock({ result == nil }), !Task.isCancelled else { return }
            guard ContinuousClock().now < deadline else { finish(.timedOut); return }
            do { let value = try await operation(); finish(.value(value)) }
            catch { finish(.failed) }
        }
        let timer = Task.detached { [self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            finish(.timedOut)
        }
        let closed = lock.withLock {
            guard result == nil else { return true }
            self.worker = worker; self.timer = timer
            return false
        }
        if closed { worker.cancel(); timer.cancel() }
    }
    private func finish(_ value: WorkflowTimedResult<Value>) {
        let resources = lock.withLock { () -> (CheckedContinuation<WorkflowTimedResult<Value>, Never>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard result == nil else { return nil }
            result = value
            let resources = (continuation, worker, timer)
            continuation = nil; worker = nil; timer = nil
            return resources
        }
        guard let resources else { return }
        resources.1?.cancel(); resources.2?.cancel()
        resources.0?.resume(returning: value)
    }
}

enum WorkflowHostCallResult: Sendable {
    case value(WorkflowHostResult), threw, cancelled, timedOut
}
enum WorkflowTimedCall {
    static func perform(deadline: ContinuousClock.Instant, host: @escaping WorkflowHostOperation, request: WorkflowHostRequest) async -> WorkflowHostCallResult {
        let value = await WorkflowHostRace<WorkflowHostResult>().perform(deadline: deadline) { try await host(request) }
        switch value {
        case .value(let result): return .value(result)
        case .failed: return .threw
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        }
    }
}
