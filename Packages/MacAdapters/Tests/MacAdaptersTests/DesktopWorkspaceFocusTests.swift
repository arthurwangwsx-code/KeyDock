import Foundation
import Testing
@preconcurrency import ApplicationServices
@testable import MacAdapters

private func process(_ pid: pid_t) -> TargetIdentity { .init(pid: pid, launchDate: Date(timeIntervalSince1970: Double(pid)), name: "Synthetic") }
@MainActor private final class WorkspaceFocusFixture {
    var foreground: TargetIdentity? = process(42001)
    var events: [String] = []
    var focused = true
    var validationFailure = false
    var onValidate: (() async -> Void)?
    var activation: ((DesktopWindowTarget) -> Bool)?
    var raise: (() async -> Void)?
    var readback: (() async -> Bool)?
    func target(_ pid: pid_t) -> DesktopWindowTarget { .init(identity: process(pid), element: AXUIElementCreateApplication(pid)) }
    func controller() -> WorkspaceWindowFocusController {
        .init(environment: .init(foreground: { self.foreground }, validate: { _ in
            await self.onValidate?()
            if self.validationFailure { throw WindowCommandError.changed }
        }, activate: { target in
            self.events.append("activate.\(target.identity.pid)")
            if let activation = self.activation { return activation(target) }
            self.foreground = target.identity; return true
        }, raiseAndFocus: { target, lease, fence in
            try lease.check(); try fence.check(); try lease.markSubmission()
            self.events.append("raise.\(target.identity.pid)"); await self.raise?()
        }, isFocused: { target, _, _ in
            self.events.append("readback.\(target.identity.pid)")
            if let readback = self.readback { return await readback() }; return self.focused
        }))
    }
}

@MainActor private final class FocusReadbackGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func waitForEntry() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered { guard ContinuousClock.now < deadline else { throw WindowCommandError.unconfirmed }; try await Task.sleep(for: .milliseconds(5)) }
    }
}

@Suite @MainActor struct DesktopWorkspaceFocusTests {
    @Test func exactChainedHandoffsAllowAToBThenBToC() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), controller = fixture.controller()
        for pid: pid_t in [42002, 42003] {
            let lease = try operations.makeChild()
            try await controller.focus(fixture.target(pid), fence: fence, lease: lease)
            #expect(lease.didSubmit); operations.release(lease)
        }
        #expect(fixture.events == ["activate.42002", "raise.42002", "readback.42002", "activate.42003", "raise.42003", "readback.42003"])
        #expect(operations.pendingChildCount == 0 && operations.isCurrent)
    }
    @Test func sameProcessDoesNotActivateButStillRaisesAndReadsOriginalWindow() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let source = TargetIdentity(pid: 42001, launchDate: process(42001).launchDate, name: "Renamed")
        let fence = try DesktopWorkspaceFocusFence(source: source, operations: operations), lease = try operations.makeChild()
        try await fixture.controller().focus(fixture.target(42001), fence: fence, lease: lease)
        #expect(fixture.events == ["raise.42001", "readback.42001"])
        await #expect(throws: DesktopOperationLeaseError.self) { try await fixture.controller().focus(fixture.target(42001), fence: fence, lease: lease) }
    }
    @Test(arguments: ["thirdParty", "returnedSource", "reusedPID"])
    func interveningActivationCannotBeHiddenByALateTarget(interference: String) async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        fixture.activation = { target in
            if interference == "returnedSource" { fence.observe(target.identity); fence.observe(process(42001)) }
            else if interference == "reusedPID" { fence.observe(.init(pid: 42002, launchDate: Date(timeIntervalSince1970: 999), name: "Synthetic")) }
            else { fence.observe(process(42003)) }
            fixture.foreground = target.identity; fence.observe(target.identity); return true
        }
        await #expect(throws: (any Error).self) { try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease) }
        #expect(fixture.events == ["activate.42002"])
        #expect(!operations.isCurrent && !lease.isCurrent && lease.didSubmit)
        #expect(throws: CancellationError.self) { try operations.makeChild() }
    }
    @Test func foregroundSamplingClosesSourcePermissionBeforeItsNotification() throws {
        let operations = DesktopOperationGroup(), fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations)
        _ = try fence.begin(to: process(42002))
        fence.observe(process(42002)); try fence.check()
        fence.observe(process(42001)); fence.observe(process(42002))
        #expect(throws: CancellationError.self) { try fence.check() }
    }
    @Test func sourcePIDReuseBeforeDispatchHasZeroNativeRequests() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        fixture.foreground = .init(pid: 42001, launchDate: Date(timeIntervalSince1970: 1), name: "Synthetic")
        await #expect(throws: CancellationError.self) { try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease) }
        #expect(fixture.events.isEmpty && !lease.didSubmit)
    }
    @Test(arguments: [false, true]) func targetAlreadyForegroundBeforeHandoffCannotAuthorizeItself(duringValidation: Bool) async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        if duringValidation { fixture.onValidate = { fixture.foreground = process(42002); await Task.yield() } }
        else { fixture.foreground = process(42002) }
        await #expect(throws: CancellationError.self) { try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease) }
        #expect(fixture.events.isEmpty && !lease.didSubmit && !operations.isCurrent)
    }
    @Test func successfulSetterCannotReplaceRequiredFocusedWindowReadback() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        fixture.focused = false
        await #expect(throws: WindowCommandError.self) { try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease, timeout: .milliseconds(1)) }
        #expect(fixture.events.contains("readback.42002") && lease.didSubmit && !operations.isCurrent)
    }
    @Test func cancellationDuringFinalReadbackCannotPublishLateSuccess() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup(), gate = FocusReadbackGate()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        fixture.readback = { await gate.wait(); return true }
        var returned = false
        let task = Task { defer { returned = true }; await #expect(throws: CancellationError.self) { try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease) } }
        try await gate.waitForEntry(); task.cancel()
        #expect(!operations.isCurrent && !lease.isCurrent && !returned)
        gate.release(); await task.value
        #expect(returned && lease.didSubmit)
    }
    @Test func finalFocusedReadbackIsNotFollowedByAnotherAsyncValidation() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        fixture.onValidate = {
            // 若在最终CFEqual之后再等待验证，同App已可换窗而App围栏不变。
            if fixture.events.contains("readback.42002") { fixture.focused = false; await Task.yield() }
        }
        try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease)
        #expect(fixture.focused)
    }
    @Test func preCancelledEntryClosesGroupBeforeAnyNativeRequest() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        let task = Task { _ = await #expect(throws: CancellationError.self) { try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease) } }
        task.cancel(); await task.value
        #expect(fixture.events.isEmpty && !lease.didSubmit && !lease.isCurrent && !operations.isCurrent)
    }
    @Test func staleCompletionCannotAdvanceTheNextHandoff() throws {
        let operations = DesktopOperationGroup(), fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations)
        let old = try fence.begin(to: process(42002)); fence.observe(process(42002)); try fence.complete(old, actual: process(42002))
        let current = try fence.begin(to: process(42003)); fence.observe(process(42003))
        #expect(throws: WindowCommandError.self) { try fence.complete(old, actual: process(42002)) }
        try fence.complete(current, actual: process(42003)); try fence.check()
    }
    @Test func failureBeforeActivationCancelsGroupWithoutSubmission() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), lease = try operations.makeChild()
        fixture.validationFailure = true
        await #expect(throws: WindowCommandError.self) { try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: lease) }
        #expect(fixture.events.isEmpty && !lease.didSubmit && !operations.isCurrent)
    }
    @Test func thirdPartyAfterFocusRevokesAlreadyRegisteredLayoutChild() async throws {
        let fixture = WorkspaceFocusFixture(), operations = DesktopOperationGroup()
        let fence = try DesktopWorkspaceFocusFence(source: process(42001), operations: operations), focus = try operations.makeChild()
        try await fixture.controller().focus(fixture.target(42002), fence: fence, lease: focus)
        operations.release(focus)
        let layout = try operations.makeChild(); fence.observe(process(42003))
        #expect(throws: CancellationError.self) { try layout.begin() }
        #expect(!layout.didSubmit && operations.pendingChildCount == 1)
        operations.release(layout); #expect(operations.pendingChildCount == 0)
    }
}

@Suite struct DesktopOperationGroupTests {
    @Test func revokeAndConcurrentRegistrationNeverLeaveLiveChildren() async throws {
        let group = DesktopOperationGroup()
        let leases = await withTaskGroup(of: DesktopOperationLease?.self, returning: [DesktopOperationLease].self) { tasks in
            for index in 0..<80 {
                tasks.addTask { if index == 40 { group.revoke() }; return try? group.makeChild() }
            }
            var result: [DesktopOperationLease] = []
            for await lease in tasks { if let lease { result.append(lease) } }
            return result
        }
        group.revoke()
        #expect(leases.allSatisfy { !$0.isCurrent })
        #expect(throws: CancellationError.self) { try group.makeChild() }
        for lease in leases { group.release(lease) }
        #expect(group.pendingChildCount == 0)
    }
}
