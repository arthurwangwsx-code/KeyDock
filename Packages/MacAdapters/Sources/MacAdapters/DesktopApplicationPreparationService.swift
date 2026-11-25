import AppKit
import CommandCore

public enum WorkspaceApplicationLaunchFact: String, Sendable { case notSubmitted, submittedUnconfirmed, confirmedReady }
public enum WorkspaceApplicationOrigin: Sendable { case alreadyRunning, observedAfterLaunchRequest }

/// 目录、缺失策略与调用围栏一并冻结；状态只留在本地内存，不写PID／路径到回执。
public final class PreparedDesktopApplication: @unchecked Sendable {
    public let initialIdentity: TargetIdentity?
    public let missingPolicy: DesktopWorkspaceMissingApplicationPolicy
    let item: CommandItem
    let owner: UUID
    let fence: DesktopWorkspaceFocusFence
    private let lock = NSLock()
    private var claimed = false
    private var fact: WorkspaceApplicationLaunchFact = .notSubmitted
    public var launchFact: WorkspaceApplicationLaunchFact { lock.withLock { fact } }
    init(item: CommandItem, identity: TargetIdentity?, missingPolicy: DesktopWorkspaceMissingApplicationPolicy, owner: UUID, fence: DesktopWorkspaceFocusFence) {
        self.item = item; initialIdentity = identity; self.missingPolicy = missingPolicy; self.owner = owner; self.fence = fence
    }
    func claim() throws { try lock.withLock { guard !claimed else { throw DesktopOperationLeaseError.alreadyUsed }; claimed = true } }
    func noteSubmission() { lock.withLock { fact = .submittedUnconfirmed } }
    func noteReady() { lock.withLock { fact = .confirmedReady } }
}

public struct ReadyDesktopApplication: Sendable {
    public let identity: TargetIdentity
    public let origin: WorkspaceApplicationOrigin
    let item: CommandItem
    let owner: UUID
    let fence: DesktopWorkspaceFocusFence
}

public struct PreparedWorkspaceApplication: Sendable {
    public let entryID: UUID
    public let plan: PreparedDesktopApplication
}

@MainActor struct WorkspaceApplicationPreparationEnvironment {
    var validatedURL: (CommandItem) async throws -> URL
    var instance: (String) throws -> TargetIdentity?
    var foreground: () -> TargetIdentity?
    var openBackground: (URL, @escaping @Sendable (TargetIdentity?) -> Void) -> Void
}

/// 不使用会激活应用的perform入口；所有启动都必须由冻结的显式缺失策略批准。
@MainActor public final class DesktopApplicationPreparationService {
    private let owner = UUID()
    private let environment: WorkspaceApplicationPreparationEnvironment
    private let launchTimeout: Duration
    private var closed = false
    private var active: [UUID: (DesktopOperationLease, DesktopWorkspaceFocusFence)] = [:]
    public convenience init(catalog: ApplicationCatalog) {
        self.init(environment: .init(validatedURL: { try await catalog.validatedURL(for: $0) }, instance: { path in
            guard let app = try WorkspaceApplicationInstanceResolver.instance(at: path) else { return nil }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, let date = app.launchDate else { throw ApplicationControlError.unavailable }
            return .init(pid: app.processIdentifier, launchDate: date, name: "")
        }, foreground: { WorkspaceWindowFocusController.foregroundIdentity() }, openBackground: { url, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false; configuration.promptsUserIfNeeded = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.createsNewApplicationInstance = false; configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                guard error == nil, let app, !app.isTerminated, app.bundleURL?.path == url.path, let date = app.launchDate else { completion(nil); return }
                completion(.init(pid: app.processIdentifier, launchDate: date, name: ""))
            }
        }))
    }
    init(environment: WorkspaceApplicationPreparationEnvironment, launchTimeout: Duration = .seconds(3)) {
        self.environment = environment; self.launchTimeout = min(.seconds(3), max(.milliseconds(1), launchTimeout))
    }
    public func close() {
        closed = true
        for (lease, fence) in active.values { fence.revoke(); lease.revoke() }
    }
    public func inspect(_ item: CommandItem, missingPolicy: DesktopWorkspaceMissingApplicationPolicy,
                        fence: DesktopWorkspaceFocusFence) async throws -> PreparedDesktopApplication {
        try await withTaskCancellationHandler { do {
            try check(fence)
            let path = try expectedPath(item)
            let before = try environment.instance(path)
            try validateIdentity(before)
            let url = try await environment.validatedURL(item)
            try check(fence)
            guard url.path == path, sameInstance(before, try environment.instance(path)) else { throw ApplicationControlError.changed }
            try check(fence)
            guard before != nil || missingPolicy == .launchInBackground else { throw ApplicationControlError.unavailable }
            return PreparedDesktopApplication(item: item, identity: before, missingPolicy: missingPolicy, owner: owner, fence: fence)
        } catch { fence.revoke(); throw error } } onCancel: { fence.revoke() }
    }
    public func inspectWorkspace(_ definition: SavedDesktopWorkspace, applications: [CommandItem],
                                 fence: DesktopWorkspaceFocusFence) async throws -> [PreparedWorkspaceApplication] {
        do {
            var result: [PreparedWorkspaceApplication] = []
            for entry in definition.entries {
                let matches = applications.filter { $0.id == entry.applicationID }
                guard matches.count == 1, let item = matches.first else { throw ApplicationControlError.unavailable }
                let plan = try await inspect(item, missingPolicy: entry.missingApplication, fence: fence)
                if let identity = plan.initialIdentity {
                    guard !result.contains(where: { DesktopWorkspaceFocusFence.sameProcess($0.plan.initialIdentity, identity) }) else { throw ApplicationControlError.ambiguous }
                }
                result.append(.init(entryID: entry.id, plan: plan))
            }
            for prepared in result { try await revalidate(prepared.plan) }
            return result
        } catch { fence.revoke(); throw error }
    }
    public func ensureRunning(_ plan: PreparedDesktopApplication, lease: DesktopOperationLease) async throws -> ReadyDesktopApplication {
        try await withTaskCancellationHandler {
            let operation = UUID()
            do {
                guard plan.owner == owner else { throw ApplicationControlError.changed }
                try lease.begin(); try plan.claim(); try check(plan.fence); try lease.check()
                active[operation] = (lease, plan.fence)
                defer { active[operation] = nil }
                let path = try expectedPath(plan.item)
                let url = try await environment.validatedURL(plan.item)
                try check(plan.fence); try lease.check()
                guard url.path == path, sameInstance(plan.initialIdentity, try environment.instance(path)) else { throw ApplicationControlError.changed }
                try check(plan.fence); try lease.check()
                if let identity = plan.initialIdentity {
                    return ReadyDesktopApplication(identity: identity, origin: .alreadyRunning, item: plan.item, owner: owner, fence: plan.fence)
                }
                guard plan.missingPolicy == .launchInBackground else { throw ApplicationControlError.unavailable }
                try check(plan.fence); try lease.check()
                let candidate = await launch(url, plan: plan, lease: lease)
                try check(plan.fence); try lease.check()
                guard let candidate else { throw ApplicationControlError.launchUnknown }
                try validateIdentity(candidate)
                let validated = try await environment.validatedURL(plan.item)
                try check(plan.fence); try lease.check()
                guard validated.path == path, sameInstance(candidate, try environment.instance(path)) else { throw ApplicationControlError.changed }
                try check(plan.fence); try lease.check()
                plan.noteReady()
                return ReadyDesktopApplication(identity: candidate, origin: .observedAfterLaunchRequest, item: plan.item, owner: owner, fence: plan.fence)
            } catch { plan.fence.revoke(); lease.revoke(); throw error }
        } onCancel: { plan.fence.revoke(); lease.revoke() }
    }
    public func revalidate(_ ready: ReadyDesktopApplication) async throws {
        try await withTaskCancellationHandler { do {
            guard ready.owner == owner else { throw ApplicationControlError.changed }
            try check(ready.fence)
            let path = try expectedPath(ready.item), url = try await environment.validatedURL(ready.item)
            try check(ready.fence)
            guard url.path == path, sameInstance(ready.identity, try environment.instance(path)) else { throw ApplicationControlError.changed }
            try check(ready.fence)
        } catch { ready.fence.revoke(); throw error } } onCancel: { ready.fence.revoke() }
    }
    public func revalidate(_ plan: PreparedDesktopApplication) async throws {
        try await withTaskCancellationHandler { do {
            guard plan.owner == owner else { throw ApplicationControlError.changed }
            try check(plan.fence)
            let path = try expectedPath(plan.item), url = try await environment.validatedURL(plan.item)
            try check(plan.fence)
            guard url.path == path, sameInstance(plan.initialIdentity, try environment.instance(path)) else { throw ApplicationControlError.changed }
            try check(plan.fence)
        } catch { plan.fence.revoke(); throw error } } onCancel: { plan.fence.revoke() }
    }
    private func check(_ fence: DesktopWorkspaceFocusFence) throws {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
        fence.observe(environment.foreground()); try fence.check()
    }
    private func expectedPath(_ item: CommandItem) throws -> String {
        guard item.kind == .application, DesktopWorkspaceEntry.validApplicationID(item.id), item.objectRevision != nil,
              item.payload == String(item.id.dropFirst(4)), item.payload != Bundle.main.bundleURL.path else { throw ApplicationControlError.unavailable }
        return item.payload
    }
    private func validateIdentity(_ identity: TargetIdentity?) throws {
        if let identity { guard identity.pid > 0, identity.pid != ProcessInfo.processInfo.processIdentifier, identity.launchDate != nil else { throw ApplicationControlError.unavailable } }
    }
    private func sameInstance(_ lhs: TargetIdentity?, _ rhs: TargetIdentity?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        return DesktopWorkspaceFocusFence.sameProcess(lhs, rhs)
    }
    private func launch(_ url: URL, plan: PreparedDesktopApplication, lease: DesktopOperationLease) async -> TargetIdentity? {
        await withCheckedContinuation { continuation in
            let gate = WorkspaceBackgroundLaunchGate(continuation)
            do {
                try check(plan.fence); try lease.check(); try lease.markSubmission(operation: .launch); plan.noteSubmission()
                environment.openBackground(url) { gate.resolve($0) }
                // 提交方法只排队；同步回调也允许先resolve，install会取消多余timer。
                let timeout = launchTimeout
                let timer = Task.detached {
                    do { try await Task.sleep(for: timeout); gate.resolve(nil) } catch {}
                }
                gate.install(timer)
            } catch { gate.resolve(nil) }
        }
    }
}

/// 原生请求不能撤回。取消立即撤销授权，但仍等待回调或原有界期限；迟到只关闭gate。
private final class WorkspaceBackgroundLaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TargetIdentity?, Never>?
    private var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<TargetIdentity?, Never>) { self.continuation = continuation }
    func install(_ timer: Task<Void, Never>) {
        let finished = lock.withLock { if continuation == nil { return true }; self.timer = timer; return false }
        if finished { timer.cancel() }
    }
    func resolve(_ value: TargetIdentity?) {
        let pending = lock.withLock { let pending = (continuation, timer); continuation = nil; timer = nil; return pending }
        pending.1?.cancel(); pending.0?.resume(returning: value)
    }
}

@MainActor enum WorkspaceApplicationInstanceResolver {
    static func instance(at path: String) throws -> NSRunningApplication? {
        let matches = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.bundleURL?.path == path }
        guard matches.count <= 1 else { throw ApplicationControlError.ambiguous }
        return matches.first
    }
}
