import Foundation
import Testing
@preconcurrency import ApplicationServices
import CommandCore
@testable import MacAdapters

private final class LayoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { started } }
    func wait() throws {
        lock.withLock { started = true }
        guard semaphore.wait(timeout: .now() + 4) == .success else { throw WindowLayoutError.unavailable }
    }
    func release() { semaphore.signal() }
    @MainActor func waitForEntry() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered { guard ContinuousClock.now < deadline else { throw WindowLayoutError.unavailable }; try await Task.sleep(for: .milliseconds(5)) }
    }
}

private final class LayoutFixture: @unchecked Sendable {
    struct State {
        var frames: [pid_t: WindowFrame] = [41001: WindowFrame(x: 30, y: 40, width: 300, height: 200), 41002: WindowFrame(x: 1100, y: 50, width: 400, height: 300)]
        var generation = UUID()
        var screens = [DisplayGeometry(id: "primary", visibleFrame: WindowFrame(x: 0, y: 0, width: 1000, height: 800)),
                       DisplayGeometry(id: "secondary", visibleFrame: WindowFrame(x: 1000, y: 0, width: 1200, height: 900))]
        var trusted = true
        var expired: Set<pid_t> = []
        var unwritable: Set<pid_t> = []
        var writes: [pid_t] = []
        var failBeforeWrite = false
        var failAfterSubmission = false
        var simulatePriorSubmission = false
        var readGate: LayoutGate?
        var writeGate: LayoutGate?
        var afterSubmissionGate: LayoutGate?
        var driftFirstWhenSecondRead = false
    }
    private let lock = NSLock()
    private var state = State()
    func withState<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { try body(&state) } }
    @MainActor func controller() -> WindowLayoutController {
        WindowLayoutController(environment: .init(trusted: { self.withState { $0.trusted } }, validate: { target in
            guard !self.withState({ $0.expired.contains(target.identity.pid) }) else { throw WindowLayoutError.expired }
        }, displays: { self.withState { ($0.generation, $0.screens) } }, generationIsCurrent: { generation in self.withState { $0.generation == generation } }, read: { target in
            let gate = self.withState { $0.readGate }; try gate?.wait()
            return try self.withState {
                if $0.driftFirstWhenSecondRead && target.identity.pid == 41002 { $0.frames[41001]?.x += 20 }
                guard let frame = $0.frames[target.identity.pid] else { throw WindowLayoutError.expired }; return frame
            }
        }, checkWritable: { target in
            guard !self.withState({ $0.unwritable.contains(target.identity.pid) }) else { throw WindowLayoutError.unsupported }
        }, write: { destination, expected, target, lease, submission in
            let gate = self.withState { $0.writeGate }; try gate?.wait()
            try lease.check(); try submission.check()
            let afterSubmission = try self.withState { state in
                if state.simulatePriorSubmission { try lease.markSubmission(operation: .activate) }
                guard !state.failBeforeWrite, state.frames[target.identity.pid]?.approximatelyEquals(expected) == true else { throw WindowLayoutError.changed }
                try lease.markSubmission(); submission.mark(); state.writes.append(target.identity.pid)
                if state.failAfterSubmission { throw WindowLayoutError.verificationFailed }
                return state.afterSubmissionGate
            }
            try afterSubmission?.wait(); try lease.check(); try submission.check()
            self.withState { $0.frames[target.identity.pid] = destination }
        }))
    }
    func target(_ pid: pid_t = 41001) -> DesktopWindowTarget {
        DesktopWindowTarget(identity: .init(pid: pid, launchDate: Date(timeIntervalSince1970: Double(pid)), name: "Synthetic"), element: AXUIElementCreateApplication(pid))
    }
}

/// 仅合成窗口、屏幕与worker；不读个人窗口，不请求系统权限。
@Suite @MainActor struct PreparedWindowLayoutTests {
    @Test func preparationIsReadOnlyAndCannotCreateRestoreHistory() async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller()
        let plan = try await controller.prepare(.rightHalf, target: target, displays: controller.captureDisplaySnapshot())
        #expect(plan.originalFrame == WindowFrame(x: 30, y: 40, width: 300, height: 200))
        #expect(plan.destinationFrame == WindowFrame(x: 500, y: 0, width: 500, height: 800))
        #expect(fixture.withState { $0.writes.isEmpty })
        await #expect(throws: WindowGeometryError.noRestoreFrame) { try await controller.prepare(.restore, target: target, displays: controller.captureDisplaySnapshot()) }
    }

    @Test func singleUsePlanAndForeignControllerCannotReplay() async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller()
        let plan = try await controller.prepare(.leftHalf, target: target, displays: controller.captureDisplaySnapshot())
        let foreign = fixture.controller()
        await #expect(throws: WindowLayoutError.self) { try await foreign.applyPrepared(plan, lease: DesktopOperationLease()) }
        try await controller.applyPrepared(plan, lease: DesktopOperationLease())
        await #expect(throws: DesktopOperationLeaseError.self) { try await controller.applyPrepared(plan, lease: DesktopOperationLease()) }
        #expect(fixture.withState { $0.writes == [41001] })
    }

    @Test(arguments: ["frame", "generation", "geometry", "process", "permission", "writable", "close"])
    func changesRejectFrozenPlanWithoutWriting(change: String) async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller()
        let plan = try await controller.prepare(.maximize, target: target, displays: controller.captureDisplaySnapshot())
        fixture.withState {
            switch change {
            case "frame": $0.frames[41001]?.x += 20
            case "generation": $0.generation = UUID()
            case "geometry": $0.screens.removeLast()
            case "process": $0.expired.insert(41001)
            case "permission": $0.trusted = false
            case "writable": $0.unwritable.insert(41001)
            default: break
            }
        }
        if change == "close" { controller.close() }
        await #expect(throws: (any Error).self) { try await controller.applyPrepared(plan, lease: DesktopOperationLease()) }
        await #expect(throws: DesktopOperationLeaseError.self) { try await controller.applyPrepared(plan, lease: DesktopOperationLease()) }
        #expect(fixture.withState { $0.writes.isEmpty })
    }

    @Test func restoreUsesFirstSubmittedLayoutAndConsumesBaselineOnlyAfterSuccess() async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller()
        let original = fixture.withState { $0.frames[41001]! }
        try await controller.apply(.leftHalf, target: target, lease: DesktopOperationLease())
        try await controller.apply(.rightHalf, target: target, lease: DesktopOperationLease())
        try await controller.apply(.restore, target: target, lease: DesktopOperationLease())
        #expect(fixture.withState { $0.frames[41001] == original })
        await #expect(throws: WindowGeometryError.noRestoreFrame) { try await controller.apply(.restore, target: target, lease: DesktopOperationLease()) }
    }

    @Test(arguments: [false, true]) func zeroFrameSubmissionDoesNotPolluteRestoreEvenAfterFocusSubmitted(focusSubmitted: Bool) async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller()
        let plan = try await controller.prepare(.maximize, target: target, displays: controller.captureDisplaySnapshot())
        fixture.withState { $0.failBeforeWrite = true; $0.simulatePriorSubmission = focusSubmitted }
        let lease = DesktopOperationLease()
        await #expect(throws: (any Error).self) { try await controller.applyPrepared(plan, lease: lease) }
        #expect(lease.didSubmit == focusSubmitted)
        fixture.withState { $0.failBeforeWrite = false; $0.simulatePriorSubmission = false; $0.frames[41001]?.x = 80 }
        let actual = fixture.withState { $0.frames[41001]! }
        try await controller.apply(.leftHalf, target: target, lease: DesktopOperationLease())
        try await controller.apply(.restore, target: target, lease: DesktopOperationLease())
        #expect(fixture.withState { $0.frames[41001] == actual })
    }

    @Test func partialFrameSubmissionRetainsRestoreAndCannotReplayFailedPlan() async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller()
        let plan = try await controller.prepare(.maximize, target: target, displays: controller.captureDisplaySnapshot()), lease = DesktopOperationLease()
        fixture.withState { $0.failAfterSubmission = true }
        await #expect(throws: WindowLayoutError.self) { try await controller.applyPrepared(plan, lease: lease) }
        #expect(lease.didSubmit)
        fixture.withState { $0.failAfterSubmission = false; $0.frames[41001]?.x = 50 }
        let restore = try await controller.prepare(.restore, target: target, displays: controller.captureDisplaySnapshot())
        #expect(restore.destinationFrame == plan.originalFrame)
        await #expect(throws: DesktopOperationLeaseError.self) { try await controller.applyPrepared(plan, lease: DesktopOperationLease()) }
    }

    @Test func oldRestoreCannotConsumeAReplacementBaselineAtTheSameFrame() async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller()
        try await controller.apply(.leftHalf, target: target, lease: DesktopOperationLease())
        let old = try await controller.prepare(.restore, target: target, displays: controller.captureDisplaySnapshot())
        try await controller.apply(.restore, target: target, lease: DesktopOperationLease())
        fixture.withState { $0.frames[41001]?.x = 90 }
        let replacement = fixture.withState { $0.frames[41001]! }
        try await controller.apply(.leftHalf, target: target, lease: DesktopOperationLease())
        await #expect(throws: WindowLayoutError.self) { try await controller.revalidate(old) }
        await #expect(throws: WindowLayoutError.self) { try await controller.applyPrepared(old, lease: DesktopOperationLease()) }
        let current = try await controller.prepare(.restore, target: target, displays: controller.captureDisplaySnapshot())
        #expect(current.destinationFrame == replacement)
        try await controller.applyPrepared(current, lease: DesktopOperationLease())
        #expect(fixture.withState { $0.frames[41001] == replacement })
    }

    @Test func distinctObjectsInOneProcessKeepSeparateRestoreBaselines() async throws {
        let fixture = LayoutFixture(), first = fixture.target(), controller = fixture.controller()
        // 两个不可相等的合成AX对象；测试端口不会对其发送任何AX消息。
        let second = DesktopWindowTarget(identity: first.identity, element: AXUIElementCreateSystemWide())
        #expect(!CFEqual(first.reference.element, second.reference.element))
        let original = fixture.withState { $0.frames[41001]! }
        try await controller.apply(.leftHalf, target: first, lease: DesktopOperationLease())
        fixture.withState { $0.frames[41001]?.x = 70 }
        let other = fixture.withState { $0.frames[41001]! }
        try await controller.apply(.rightHalf, target: second, lease: DesktopOperationLease())
        let a = try await controller.prepare(.restore, target: first, displays: controller.captureDisplaySnapshot())
        let b = try await controller.prepare(.restore, target: second, displays: controller.captureDisplaySnapshot())
        #expect(a.destinationFrame == original)
        #expect(b.destinationFrame == other)
    }

    @Test func batchPreparesAllTargetsAndRejectsSecondUnwritableBeforeAnyLayout() async throws {
        let fixture = LayoutFixture(), controller = fixture.controller()
        let requests = [DesktopWorkspaceWindowRequest(entryID: UUID(), target: fixture.target(), layout: .leftHalf, display: .windowDisplay),
                        DesktopWorkspaceWindowRequest(entryID: UUID(), target: fixture.target(41002), layout: .rightHalf, display: .mainDisplay)]
        _ = fixture.withState { $0.unwritable.insert(41002) }
        await #expect(throws: WindowLayoutError.self) { try await controller.prepareWorkspaceWindows(requests, displays: controller.captureDisplaySnapshot(), invocationDisplayID: nil) }
        #expect(fixture.withState { $0.writes.isEmpty })
        _ = fixture.withState { $0.unwritable.remove(41002) }
        let plans = try await controller.prepareWorkspaceWindows(requests, displays: controller.captureDisplaySnapshot(), invocationDisplayID: nil)
        #expect(plans.map(\.entryID) == requests.map(\.entryID))
        #expect(plans[1].plan.destinationFrame == WindowFrame(x: 500, y: 0, width: 500, height: 800))
        #expect(fixture.withState { $0.writes.isEmpty })
    }

    @Test func batchRevalidatesTheFirstTargetAfterPreparingTheSecond() async throws {
        let fixture = LayoutFixture(), controller = fixture.controller()
        fixture.withState { $0.driftFirstWhenSecondRead = true }
        let requests = [DesktopWorkspaceWindowRequest(entryID: UUID(), target: fixture.target(), layout: .leftHalf, display: .windowDisplay),
                        DesktopWorkspaceWindowRequest(entryID: UUID(), target: fixture.target(41002), layout: .rightHalf, display: .windowDisplay)]
        await #expect(throws: WindowLayoutError.self) { try await controller.prepareWorkspaceWindows(requests, displays: controller.captureDisplaySnapshot(), invocationDisplayID: nil) }
        #expect(fixture.withState { $0.writes.isEmpty })
    }

    @Test func concurrentPlanConsumptionCannotStartASecondWorker() async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller(), gate = LayoutGate()
        let plan = try await controller.prepare(.maximize, target: target, displays: controller.captureDisplaySnapshot())
        fixture.withState { $0.readGate = gate }
        let first = Task { try await controller.applyPrepared(plan, lease: DesktopOperationLease()) }
        try await gate.waitForEntry()
        await #expect(throws: DesktopOperationLeaseError.self) { try await controller.applyPrepared(plan, lease: DesktopOperationLease()) }
        gate.release(); try await first.value
        #expect(fixture.withState { $0.writes == [41001] })
    }

    @Test func topologyChangeAfterFirstFrameSubmissionStopsRemainingWritesAndKeepsRestore() async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller(), gate = LayoutGate()
        let plan = try await controller.prepare(.maximize, target: target, displays: controller.captureDisplaySnapshot()), lease = DesktopOperationLease()
        fixture.withState { $0.afterSubmissionGate = gate }
        let task = Task { _ = await #expect(throws: WindowLayoutError.self) { try await controller.applyPrepared(plan, lease: lease) } }
        try await gate.waitForEntry(); fixture.withState { $0.generation = UUID() }; gate.release(); await task.value
        #expect(lease.didSubmit && fixture.withState { $0.writes == [41001] })
        fixture.withState { $0.afterSubmissionGate = nil; $0.frames[41001]?.x = 60 }
        let restore = try await controller.prepare(.restore, target: target, displays: controller.captureDisplaySnapshot())
        #expect(restore.destinationFrame == plan.originalFrame)
    }

    @Test func invocationDisplayIsExplicitAndDuplicateProcessCannotBeBoundTwice() async throws {
        let fixture = LayoutFixture(), controller = fixture.controller()
        let request = DesktopWorkspaceWindowRequest(entryID: UUID(), target: fixture.target(), layout: .maximize, display: .invocationDisplay)
        await #expect(throws: WindowLayoutError.self) { try await controller.prepareWorkspaceWindows([request], displays: controller.captureDisplaySnapshot(), invocationDisplayID: nil) }
        let plans = try await controller.prepareWorkspaceWindows([request], displays: controller.captureDisplaySnapshot(), invocationDisplayID: "secondary")
        #expect(plans[0].plan.destinationFrame == WindowFrame(x: 1000, y: 0, width: 1200, height: 900))
        let duplicate = DesktopWorkspaceWindowRequest(entryID: UUID(), target: fixture.target(), layout: .leftHalf, display: .windowDisplay)
        await #expect(throws: WindowLayoutError.self) { try await controller.prepareWorkspaceWindows([request, duplicate], displays: controller.captureDisplaySnapshot(), invocationDisplayID: "primary") }
        #expect(fixture.withState { $0.writes.isEmpty })
    }

    @Test(arguments: ["read", "write", "topology"]) func cancelledOrChangedWorkersDrainBeforeReturning(stage: String) async throws {
        let fixture = LayoutFixture(), target = fixture.target(), controller = fixture.controller(), gate = LayoutGate()
        let plan = try await controller.prepare(.maximize, target: target, displays: controller.captureDisplaySnapshot()), lease = DesktopOperationLease()
        fixture.withState { if stage == "read" { $0.readGate = gate } else { $0.writeGate = gate } }
        var returned = false
        let task = Task { defer { returned = true }; await #expect(throws: (any Error).self) { try await controller.applyPrepared(plan, lease: lease) } }
        try await gate.waitForEntry()
        if stage == "topology" { fixture.withState { $0.generation = UUID() } } else { task.cancel() }
        try await Task.sleep(for: .milliseconds(15))
        #expect(!returned)
        gate.release(); await task.value
        #expect(returned && fixture.withState { $0.writes.isEmpty })
        if stage == "write" { #expect(!lease.isCurrent) }
    }
}
