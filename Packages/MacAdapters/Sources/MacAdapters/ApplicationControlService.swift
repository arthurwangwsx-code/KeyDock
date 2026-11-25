import AppKit
import CommandCore

public struct ApplicationControlState: Sendable {
    public let exists: Bool
    public let hidden: Bool
    public let active: Bool
    public init(exists: Bool, hidden: Bool = false, active: Bool = false) { self.exists = exists; self.hidden = hidden; self.active = active }
}
public enum ApplicationDispatchResult: Equatable { case accepted, rejected, partial }

/// 合成端口可验证状态机；测试不对用户应用发请求。
@MainActor public struct ApplicationControlTransaction {
    public let validate: @MainActor () async throws -> Void
    public let state: @MainActor () -> ApplicationControlState
    public let dispatch: @MainActor (ApplicationBehavior) -> ApplicationDispatchResult
    public init(validate: @escaping @MainActor () async throws -> Void, state: @escaping @MainActor () -> ApplicationControlState,
                dispatch: @escaping @MainActor (ApplicationBehavior) -> ApplicationDispatchResult) {
        self.validate = validate; self.state = state; self.dispatch = dispatch
    }
    public func run(_ behavior: ApplicationBehavior, wasFrontmost: Bool, lease: DesktopOperationLease, timeout: Duration = .milliseconds(650)) async throws -> DesktopControlOutcome {
        try lease.begin()
        return try await execute(behavior, wasFrontmost: wasFrontmost, lease: lease, timeout: timeout)
    }
    fileprivate func execute(_ behavior: ApplicationBehavior, wasFrontmost: Bool, lease: DesktopOperationLease, timeout: Duration) async throws -> DesktopControlOutcome {
        let resolved: ApplicationBehavior = behavior == .toggleVisibility ? (wasFrontmost ? .hide : .show) : behavior
        try lease.check(); try await validate(); try lease.check()
        let before = state()
        if !before.exists { return resolved == .hide || resolved == .requestQuit ? .noOp : .declined }
        if resolved == .hide && before.hidden { return .noOp }
        if (resolved == .show || resolved == .launchOrActivate) && before.active && !before.hidden { return .noOp }
        try lease.markSubmission()
        let acknowledgement = dispatch(resolved)
        var observedMutation = false
        let deadline = ContinuousClock.now.advanced(by: min(.seconds(2), max(.milliseconds(1), timeout)))
        repeat {
            try lease.check()
            let current = state()
            if current.exists != before.exists || current.hidden != before.hidden || current.active != before.active { observedMutation = true }
            let confirmed = switch resolved {
            case .requestQuit: !current.exists
            case .hide: current.exists && current.hidden
            default: current.exists && !current.hidden && current.active
            }
            if confirmed {
                // 公开接口的返回与跨进程状态更新可能不同步；不重发，只核对最终目标状态。
                if resolved == .showAllWindows { return acknowledgement == .accepted ? .requestSubmitted : .outcomeUnknown }
                return .confirmed
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        // 正常退出可能仍在等待用户保存；不再发第二次terminate。
        if acknowledgement == .rejected { return observedMutation ? .outcomeUnknown : .declined }
        return resolved == .requestQuit && acknowledgement == .accepted ? .requestSubmitted : .outcomeUnknown
    }
}

public enum ApplicationControlError: Error { case unavailable, changed, ambiguous, launchUnknown }

@MainActor public final class ApplicationControlService {
    private let catalog: ApplicationCatalog
    public init(catalog: ApplicationCatalog) { self.catalog = catalog }
    public func perform(_ behavior: ApplicationBehavior, item: CommandItem, original: TargetIdentity?, lease: DesktopOperationLease) async throws -> DesktopControlOutcome {
        try lease.begin()
        let expectedPath = String(item.id.dropFirst(4))
        guard expectedPath != Bundle.main.bundleURL.path else { throw ApplicationControlError.unavailable }
        let initial = try instance(at: expectedPath)
        guard initial?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw ApplicationControlError.unavailable }
        let frozenPID = initial?.processIdentifier, frozenDate = initial?.launchDate
        let wasFrontmost = frozenPID != nil && frozenPID == original?.pid && frozenDate == original?.launchDate
        let url = try await catalog.validatedURL(for: item)
        try lease.check()
        guard url.path == expectedPath else { throw ApplicationControlError.changed }
        var target = initial
        if let initial {
            guard initial.launchDate != nil, !initial.isTerminated,
                  try instance(at: expectedPath)?.processIdentifier == frozenPID else { throw ApplicationControlError.changed }
        } else if behavior.mayLaunch {
            guard try instance(at: expectedPath) == nil else { throw ApplicationControlError.changed }
            try lease.markSubmission(operation: .launch)
            let opened = await launch(url)
            try lease.check()
            guard let opened, let app = NSRunningApplication(processIdentifier: opened.pid), app.launchDate == opened.date,
                  !app.isTerminated, app.bundleURL?.path == expectedPath else { throw ApplicationControlError.launchUnknown }
            target = app
        } else { return behavior == .hide || behavior == .requestQuit ? .noOp : .declined }
        guard let app = target, let launchDate = app.launchDate else { throw ApplicationControlError.unavailable }
        let pid = app.processIdentifier
        let transaction = ApplicationControlTransaction(validate: { [catalog] in
            _ = try await catalog.validatedURL(for: item)
            guard app.launchDate == launchDate, !app.isTerminated, app.bundleURL?.path == expectedPath,
                  try self.instance(at: expectedPath)?.processIdentifier == pid else { throw ApplicationControlError.changed }
        }, state: {
            ApplicationControlState(exists: !app.isTerminated && app.launchDate == launchDate, hidden: app.isHidden, active: app.isActive)
        }, dispatch: { action in
            guard (try? lease.check()) != nil else { return .rejected }
            switch action {
            case .hide:
                guard (try? lease.markSubmission(operation: .hide)) != nil else { return .rejected }
                return app.hide() ? .accepted : .rejected
            case .requestQuit:
                guard (try? lease.markSubmission(operation: .quit)) != nil else { return .rejected }
                return app.terminate() ? .accepted : .rejected
            default:
                return ApplicationPresentationSteps.perform(needsUnhide: app.isHidden, validate: {
                    (try? lease.check()) != nil && !app.isTerminated && app.launchDate == launchDate && app.processIdentifier == pid && app.bundleURL?.path == expectedPath
                }, unhide: {
                    guard (try? lease.markSubmission(operation: .unhide)) != nil else { return false }
                    return app.unhide()
                }, activate: {
                    guard (try? lease.markSubmission(operation: .activate)) != nil else { return false }
                    return app.activate(options: action == .showAllWindows ? [.activateAllWindows] : [])
                })
            }
        })
        return try await transaction.execute(behavior, wasFrontmost: wasFrontmost, lease: lease, timeout: .milliseconds(650))
    }
    private func instance(at path: String) throws -> NSRunningApplication? {
        try WorkspaceApplicationInstanceResolver.instance(at: path)
    }
    private struct Launched: Sendable { let pid: pid_t; let date: Date? }
    private func launch(_ url: URL) async -> Launched? {
        await withCheckedContinuation { continuation in
            let gate = ApplicationLaunchGate(continuation)
            let deadline = Task.detached {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { gate.resolve(nil) }
            }
            gate.install(deadline)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false; configuration.promptsUserIfNeeded = false
            configuration.allowsRunningApplicationSubstitution = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                gate.resolve(error == nil ? app.map { Launched(pid: $0.processIdentifier, date: $0.launchDate) } : nil)
            }
        }
    }
    private final class ApplicationLaunchGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Launched?, Never>?
        private var deadline: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<Launched?, Never>) { self.continuation = continuation }
        func install(_ task: Task<Void, Never>) {
            lock.lock(); let finished = continuation == nil; if !finished { deadline = task }; lock.unlock()
            if finished { task.cancel() }
        }
        func resolve(_ value: Launched?) {
            lock.lock(); let pending = continuation; continuation = nil; let timer = deadline; deadline = nil; lock.unlock()
            timer?.cancel(); pending?.resume(returning: value)
        }
    }
}
