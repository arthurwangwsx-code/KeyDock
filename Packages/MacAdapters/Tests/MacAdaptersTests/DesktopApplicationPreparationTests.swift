import Foundation
import Testing
import CommandCore
@testable import MacAdapters

private func applicationProcess(_ pid: pid_t) -> TargetIdentity { .init(pid: pid + 1_000_000, launchDate: Date(timeIntervalSince1970: Double(pid)), name: "Synthetic") }

@MainActor private final class ApplicationPreparationGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class ApplicationPreparationFixture {
    var foreground: TargetIdentity? = applicationProcess(71001)
    var instances: [String: [TargetIdentity]] = [:]
    var revisions: [String: String] = [:]
    var validations: [String: Int] = [:]
    var calls: [String] = []
    var completions: [@Sendable (TargetIdentity?) -> Void] = []
    var onValidate: ((CommandItem) async throws -> Void)?
    var onInstance: ((String) -> Void)?
    var onOpen: ((URL, @escaping @Sendable (TargetIdentity?) -> Void) -> Void)?
    func item(_ name: String = "A") -> CommandItem {
        let path = "/Applications/Synthetic-\(name).app"
        revisions[path] = "revision1"
        return .init(id: "app." + path, title: "Synthetic", kind: .application, payload: path, objectRevision: "revision1")
    }
    func fence() throws -> DesktopWorkspaceFocusFence { try .init(source: applicationProcess(71001), operations: DesktopOperationGroup()) }
    func service(timeout: Duration = .seconds(3)) -> DesktopApplicationPreparationService {
        .init(environment: .init(validatedURL: { item in
            self.validations[item.payload, default: 0] += 1
            try await self.onValidate?(item)
            guard self.revisions[item.payload] == item.objectRevision else { throw ApplicationCatalogError.unavailable }
            return URL(fileURLWithPath: item.payload)
        }, instance: { path in
            self.onInstance?(path)
            let matches = self.instances[path] ?? []
            guard matches.count <= 1 else { throw ApplicationControlError.ambiguous }
            return matches.first
        }, foreground: { self.foreground }, openBackground: { url, completion in
            self.calls.append(url.path); self.completions.append(completion)
            if let onOpen = self.onOpen { onOpen(url, completion) }
            else {
                let identity = applicationProcess(71002)
                self.instances[url.path] = [identity]; completion(identity)
            }
        }), launchTimeout: timeout)
    }
    func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() { guard ContinuousClock.now < deadline else { throw ApplicationControlError.unavailable }; try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// 全部应用、目录和回调为合成端口，不调用NSWorkspace或访问真实应用目录。
@Suite @MainActor struct DesktopApplicationPreparationTests {
    @Test func runningApplicationReturnsExactIdentityWithoutLaunch() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        f.instances[item.payload] = [applicationProcess(71002)]
        let plan = try await service.inspect(item, missingPolicy: .requireRunning, fence: fence), lease = try fence.operations.makeChild()
        let ready = try await service.ensureRunning(plan, lease: lease)
        #expect(ready.identity == applicationProcess(71002) && ready.origin == .alreadyRunning)
        #expect(plan.launchFact == .notSubmitted && !lease.didSubmit && f.calls.isEmpty)
        try await service.revalidate(ready)
        f.instances[item.payload] = [applicationProcess(71003)]
        await #expect(throws: ApplicationControlError.self) { try await service.revalidate(ready) }
    }
    @Test func missingRequiredApplicationFailsBeforeAnyRequest() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        await #expect(throws: ApplicationControlError.self) { try await service.inspect(item, missingPolicy: .requireRunning, fence: fence) }
        #expect(f.calls.isEmpty && !fence.operations.isCurrent)
    }
    @Test func synchronousAndDuplicateCallbacksResolveOnceAndCannotReplayPlan() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        f.onOpen = { url, callback in
            f.instances[url.path] = [applicationProcess(71002)]
            callback(applicationProcess(71002)); callback(applicationProcess(71003))
        }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        let ready = try await service.ensureRunning(plan, lease: lease)
        #expect(ready.identity == applicationProcess(71002) && ready.origin == .observedAfterLaunchRequest)
        #expect(plan.launchFact == .confirmedReady && lease.didSubmit && lease.lastNativeOperation == .launch)
        let second = try fence.operations.makeChild()
        await #expect(throws: DesktopOperationLeaseError.self) { try await service.ensureRunning(plan, lease: second) }
        #expect(f.calls.count == 1 && plan.launchFact == .confirmedReady)
    }
    @Test func concurrentCallbacksAndDeadlineChooseOneOutcome() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service(timeout: .milliseconds(1))
        var workers: [Task<Void, Never>] = []
        f.onOpen = { url, callback in
            let identity = applicationProcess(71002); f.instances[url.path] = [identity]
            workers = (0..<8).map { _ in Task.detached { callback(identity) } }
        }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        let ready = try? await service.ensureRunning(plan, lease: lease)
        for worker in workers { await worker.value }
        let fact = plan.launchFact
        f.completions[0](nil)
        #expect(f.calls.count == 1 && lease.didSubmit && plan.launchFact == fact)
        #expect(ready == nil ? fact == .submittedUnconfirmed : fact == .confirmedReady)
    }
    @Test(arguments: ["startedExternally", "quit", "replaced", "ambiguous"])
    func changedInspectionCannotRetargetOrRelaunch(change: String) async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        if change == "quit" { f.instances[item.payload] = [applicationProcess(71002)] }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        switch change {
        case "startedExternally": f.instances[item.payload] = [applicationProcess(71002)]
        case "quit": f.instances[item.payload] = []
        case "replaced": f.revisions[item.payload] = "revision2"
        default: f.instances[item.payload] = [applicationProcess(71002), applicationProcess(71003)]
        }
        await #expect(throws: (any Error).self) { try await service.ensureRunning(plan, lease: lease) }
        #expect(f.calls.isEmpty && !lease.didSubmit && plan.launchFact == .notSubmitted)
    }
    @Test(arguments: ["pid", "date", "ambiguous", "catalog", "nil"])
    func callbackMustMatchRevalidatedDirectoryAndUniqueInstance(change: String) async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        f.onOpen = { url, callback in
            f.instances[url.path] = [applicationProcess(71002)]
            switch change {
            case "pid": callback(applicationProcess(71003))
            case "date": callback(.init(pid: 71002, launchDate: nil, name: "Synthetic"))
            case "ambiguous": f.instances[url.path]?.append(applicationProcess(71003)); callback(applicationProcess(71002))
            case "catalog": f.revisions[url.path] = "revision2"; callback(applicationProcess(71002))
            default: callback(nil)
            }
        }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        await #expect(throws: (any Error).self) { try await service.ensureRunning(plan, lease: lease) }
        #expect(f.calls.count == 1 && lease.didSubmit && plan.launchFact == .submittedUnconfirmed)
    }
    @Test func timeoutDoesNotAcceptLateCallbackOrRetry() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service(timeout: .milliseconds(10))
        f.onOpen = { _, _ in }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        await #expect(throws: ApplicationControlError.self) { try await service.ensureRunning(plan, lease: lease) }
        f.instances[item.payload] = [applicationProcess(71002)]
        f.completions[0](applicationProcess(71002)); f.completions[0](applicationProcess(71003))
        #expect(f.calls.count == 1 && lease.didSubmit && plan.launchFact == .submittedUnconfirmed && !fence.operations.isCurrent)
    }
    @Test func cancellationAfterSubmissionClosesAuthorizationButWaitsForGateDrain() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        f.onOpen = { _, _ in }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        var returned = false
        let task = Task { defer { returned = true }; _ = await #expect(throws: CancellationError.self) { try await service.ensureRunning(plan, lease: lease) } }
        try await f.waitUntil { f.calls.count == 1 }; task.cancel()
        #expect(!returned && !fence.operations.isCurrent && !lease.isCurrent)
        f.instances[item.payload] = [applicationProcess(71002)]; f.completions[0](applicationProcess(71002))
        await task.value
        #expect(returned && lease.didSubmit && plan.launchFact == .submittedUnconfirmed)
    }
    @Test func cancelledInspectionImmediatelyClosesGroupAndWaitsForReadOnlyWork() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service(), gate = ApplicationPreparationGate()
        f.onValidate = { _ in await gate.wait() }
        var returned = false
        let task = Task { defer { returned = true }; _ = await #expect(throws: CancellationError.self) { try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence) } }
        try await f.waitUntil { gate.entered }; task.cancel()
        #expect(!returned && !fence.operations.isCurrent && f.calls.isEmpty)
        gate.release(); await task.value; #expect(returned)
    }
    @Test func preCancelledEnsureNeverSubmits() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        let task = Task { _ = await #expect(throws: CancellationError.self) { try await service.ensureRunning(plan, lease: lease) } }
        task.cancel(); await task.value
        #expect(f.calls.isEmpty && !lease.didSubmit && !fence.operations.isCurrent && plan.launchFact == .notSubmitted)
    }
    @Test func applicationActivatingItselfStopsPreparationWithoutBroadWhitelist() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        f.onOpen = { url, callback in
            f.instances[url.path] = [applicationProcess(71002)]; f.foreground = applicationProcess(71002); callback(applicationProcess(71002))
        }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        await #expect(throws: CancellationError.self) { try await service.ensureRunning(plan, lease: lease) }
        #expect(f.calls.count == 1 && lease.didSubmit && plan.launchFact == .submittedUnconfirmed)
    }
    @Test(arguments: [false, true]) func cancellationInFinalInstanceQueryCannotPublishReady(launch: Bool) async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        if !launch { f.instances[item.payload] = [applicationProcess(71002)] }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        f.onInstance = { _ in if !launch || !f.calls.isEmpty { fence.revoke() } }
        await #expect(throws: CancellationError.self) { try await service.ensureRunning(plan, lease: lease) }
        #expect(plan.launchFact == (launch ? .submittedUnconfirmed : .notSubmitted))
        #expect(f.calls.count == (launch ? 1 : 0))
    }
    @Test(arguments: ["inspect", "plan", "ready"])
    func finalInstanceCancellationAlsoRejectsReadOnlyValidation(mode: String) async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        f.instances[item.payload] = [applicationProcess(71002)]
        if mode == "inspect" {
            var reads = 0
            f.onInstance = { _ in reads += 1; if reads == 2 { fence.revoke() } }
            await #expect(throws: CancellationError.self) { try await service.inspect(item, missingPolicy: .requireRunning, fence: fence) }
        } else {
            let plan = try await service.inspect(item, missingPolicy: .requireRunning, fence: fence)
            if mode == "ready" {
                let ready = try await service.ensureRunning(plan, lease: fence.operations.makeChild())
                f.onInstance = { _ in fence.revoke() }
                await #expect(throws: CancellationError.self) { try await service.revalidate(ready) }
            } else {
                f.onInstance = { _ in fence.revoke() }
                await #expect(throws: CancellationError.self) { try await service.revalidate(plan) }
            }
        }
        #expect(f.calls.isEmpty && !fence.operations.isCurrent)
    }
    @Test func wholeWorkspaceInspectionRejectsLaterMissingTargetBeforeLaunchingFirst() async throws {
        let f = ApplicationPreparationFixture(), a = f.item("A"), b = f.item("B"), fence = try f.fence(), service = f.service()
        let definition = try SavedDesktopWorkspace(name: "Synthetic", entries: [.init(applicationID: a.id, missingApplication: .launchInBackground), .init(applicationID: b.id)])
        await #expect(throws: ApplicationControlError.self) { try await service.inspectWorkspace(definition, applications: [a, b], fence: fence) }
        #expect(f.calls.isEmpty)
    }
    @Test(arguments: [false, true]) func workspaceRejectsDuplicateProcessAndLateFirstTargetDrift(drift: Bool) async throws {
        let f = ApplicationPreparationFixture(), a = f.item("A"), b = f.item("B"), fence = try f.fence(), service = f.service()
        f.instances[a.payload] = [applicationProcess(71002)]; f.instances[b.payload] = [applicationProcess(drift ? 71003 : 71002)]
        if drift { f.onValidate = { item in if item.id == b.id { f.instances[a.payload] = [applicationProcess(71004)] } } }
        let definition = try SavedDesktopWorkspace(name: "Synthetic", entries: [.init(applicationID: a.id), .init(applicationID: b.id)])
        await #expect(throws: ApplicationControlError.self) { try await service.inspectWorkspace(definition, applications: [a, b], fence: fence) }
        #expect(f.calls.isEmpty)
    }
    @Test func firstConfirmedSecondUnconfirmedAndThirdUnexecutedFactsRemainDistinct() async throws {
        let f = ApplicationPreparationFixture(), a = f.item("A"), b = f.item("B"), c = f.item("C"), fence = try f.fence(), service = f.service(timeout: .milliseconds(10))
        f.onOpen = { url, callback in if url.path == a.payload { f.instances[url.path] = [applicationProcess(71002)]; callback(applicationProcess(71002)) } }
        let definition = try SavedDesktopWorkspace(name: "Synthetic", entries: [a,b,c].map { try .init(applicationID: $0.id, missingApplication: .launchInBackground) })
        let plans = try await service.inspectWorkspace(definition, applications: [a,b,c], fence: fence)
        var ready: [ReadyDesktopApplication] = []
        for prepared in plans {
            let lease = try fence.operations.makeChild()
            do { ready.append(try await service.ensureRunning(prepared.plan, lease: lease)); fence.operations.release(lease) }
            catch { fence.operations.release(lease); break }
        }
        #expect(ready.count == 1 && f.calls == [a.payload,b.payload])
        #expect(plans.map { $0.plan.launchFact } == [.confirmedReady,.submittedUnconfirmed,.notSubmitted])
    }
    @Test func closeDrainsSubmittedRequestAndForeignPlanCannotDispatch() async throws {
        let f = ApplicationPreparationFixture(), item = f.item(), fence = try f.fence(), service = f.service()
        f.onOpen = { _, _ in }
        let plan = try await service.inspect(item, missingPolicy: .launchInBackground, fence: fence), lease = try fence.operations.makeChild()
        let task = Task { _ = await #expect(throws: CancellationError.self) { try await service.ensureRunning(plan, lease: lease) } }
        try await f.waitUntil { !f.calls.isEmpty }; service.close(); f.completions[0](applicationProcess(71002)); await task.value
        #expect(!lease.isCurrent && plan.launchFact == .submittedUnconfirmed)
        let otherFence = try f.fence(), other = f.service()
        let foreign = try await other.inspect(item, missingPolicy: .launchInBackground, fence: otherFence), foreignLease = try otherFence.operations.makeChild()
        await #expect(throws: ApplicationControlError.self) { try await f.service().ensureRunning(foreign, lease: foreignLease) }
        #expect(f.calls.count == 1 && foreign.launchFact == .notSubmitted)
    }
}
