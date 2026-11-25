import Foundation
import Testing
import CommandCore
import ExecutionCore
@testable import MacAdapters

@MainActor private final class WorkspaceRunnerGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func enteredWithinDeadline() async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered { guard ContinuousClock.now < end else { throw WindowLayoutError.unavailable }; await Task.yield() }
    }
}
@MainActor private final class WorkspaceRunnerFixture {
    let parent = UUID(), group = DesktopOperationGroup()
    let definition: SavedDesktopWorkspace
    var events: [String] = []
    var missing: [Bool]
    var failPreflight = false
    var failRevalidation = false
    var failBegin: DesktopWorkspaceReceiptPhase?
    var failParentBegin = false
    var failFinish: DesktopWorkspaceReceiptPhase?
    var failParentFinish = false
    var failOperation: (Int, DesktopWorkspaceReceiptPhase, Bool)?
    var pending: [UUID: DesktopWorkspaceReceiptContext] = [:]
    var finishedParent: DesktopWorkspaceRunResult?
    var gate: WorkspaceRunnerGate?
    var gatePhase: DesktopWorkspaceReceiptPhase = .layout
    init(count: Int = 3, missing: [Bool]? = nil) throws {
        definition = try .init(name: "Synthetic workspace", entries: (0..<count).map { try .init(applicationID: "app./Applications/Synthetic\($0).app", missingApplication: .launchInBackground) })
        self.missing = missing ?? Array(repeating: false, count: count)
    }
    func operations() -> DesktopWorkspaceRunOperations {
        .init(preflight: {
            self.events += ["inspectAll", "prepareAllExisting"]
            if self.failPreflight { throw WindowLayoutError.unsupported }; return self.missing
        }, launch: { try await self.perform($0, phase: .launch, lease: $1) }, prepareLaunchedWindow: { self.events.append("prepareNew.\($0)") },
        revalidateAll: { self.events.append("revalidateAll"); if self.failRevalidation { throw WindowLayoutError.changed } },
        focus: { try await self.perform($0, phase: .focus, lease: $1) }, layout: { try await self.perform($0, phase: .layout, lease: $1) },
        check: { try self.group.check() }, close: { self.events.append("close") })
    }
    func perform(_ index: Int, phase: DesktopWorkspaceReceiptPhase, lease: DesktopOperationLease) async throws {
        try lease.begin()
        let failure = failOperation.map { $0.0 == index && $0.1 == phase } == true
        if failure && failOperation?.2 == false { throw WindowLayoutError.unsupported }
        try lease.markSubmission(); events.append("\(phase.rawValue).\(index)")
        if phase == gatePhase, let gate { await gate.wait(); try lease.check() }
        if failure { throw WindowLayoutError.verificationFailed }
    }
    var journal: DesktopWorkspaceJournal {
        .init(begin: { id, context in
            if let context {
                self.events.append("intent.\(context.phase.rawValue).\(context.entryIndex)")
                if self.failBegin == context.phase { throw InvocationStoreError.io(5) }
                self.pending[id] = context
            } else { self.events.append("parentIntent"); if self.failParentBegin { throw InvocationStoreError.io(5) } }
        }, finish: { id, _, result in
            if let result { self.events.append("parentFinish"); if self.failParentFinish { throw InvocationStoreError.io(5) }; self.finishedParent = result }
            else if self.pending[id]?.phase == self.failFinish { throw InvocationStoreError.io(5) }
        }, abandon: { _ in self.events.append("abandon") }, release: { _ in }, releaseParent: { _ in self.events.append("releaseParent") })
    }
    func run(didFocus: @escaping @MainActor () -> Void = {}) async -> DesktopWorkspaceRunResult {
        let runner = DesktopWorkspaceRunner(factory: { _,_,_,_,_,_,_ in self.operations() })
        return await runner.run(id: parent, definition: definition, catalog: [], source: .init(pid: 1_000_001, launchDate: Date(timeIntervalSince1970: 42), name: ""),
            invocationDisplayID: nil, group: group, journal: journal, didFocus: didFocus)
    }
}

@Suite @MainActor struct DesktopWorkspaceRunnerTests {
    @Test func orderedPreflightIntentsAndFreshLeasesPrecedeAllEffects() async throws {
        let f = try WorkspaceRunnerFixture(missing: [true,false,true])
        var callbacks = 0
        let report = await f.run { callbacks += 1 }
        #expect(report.state == .succeeded && callbacks == 3 && report.entries.allSatisfy { $0.layout == .confirmed })
        #expect(report.entries.map(\.launch) == [.confirmed,.notRequired,.confirmed])
        #expect(f.events.prefix(3) == ["parentIntent","inspectAll","prepareAllExisting"])
        #expect(f.events.firstIndex(of: "revalidateAll")! > f.events.firstIndex(of: "prepareNew.2")!)
        for index in 0..<3 { for phase in [DesktopWorkspaceReceiptPhase.focus,.layout] {
            #expect(f.events.firstIndex(of: "intent.\(phase.rawValue).\(index)")! < f.events.firstIndex(of: "\(phase.rawValue).\(index)")!)
        } }
        #expect(f.group.pendingChildCount == 0 && !f.group.isCurrent && f.finishedParent == report)
    }
    @Test func existingWindowFailureBeforeLaunchProducesZeroEffects() async throws {
        let f = try WorkspaceRunnerFixture(missing: [true,false,true]); f.failPreflight = true
        let report = await f.run()
        #expect(report.state == .failed && f.pending.isEmpty && report.entries.allSatisfy { $0.launch == .notExecuted && $0.layout == .notExecuted })
        #expect(!f.events.contains { $0.hasPrefix("launch.") || $0.hasPrefix("focus.") || $0.hasPrefix("layout.") })
    }
    @Test func failedGlobalRevalidationRetainsLaunchFactsAndNeverFocuses() async throws {
        let f = try WorkspaceRunnerFixture(missing: [true,false,true]); f.failRevalidation = true
        let report = await f.run()
        #expect(report.state == .interrupted && report.entries[0].launch == .confirmed && report.entries[2].launch == .confirmed)
        #expect(!f.events.contains("focus.0") && report.entries.allSatisfy { $0.layout == .notExecuted })
    }
    @Test(arguments: [true,false]) func secondLayoutFailureKeepsFirstKnownAndThirdUndispatched(submitted: Bool) async throws {
        let f = try WorkspaceRunnerFixture(); f.failOperation = (1,.layout,submitted)
        let report = await f.run()
        #expect(report.state == .interrupted && report.entries[0].layout == .confirmed && report.entries[1].focus == .confirmed)
        #expect(report.entries[1].layout == (submitted ? .unknown : .declined))
        #expect(report.entries[2].focus == .notExecuted && report.entries[2].layout == .notExecuted && !f.events.contains("focus.2"))
    }
    @Test(arguments: [DesktopWorkspaceReceiptPhase.launch,.focus,.layout]) func failedIntentNeverDispatchesItsPhase(phase: DesktopWorkspaceReceiptPhase) async throws {
        let f = try WorkspaceRunnerFixture(missing: [true,false,false]); f.failBegin = phase
        let report = await f.run()
        #expect(report.receiptUncertain && report.state == .interrupted && f.events.contains("abandon"))
        #expect(!f.events.contains("\(phase.rawValue).0") && report.entries[0][phase] == .notExecuted)
        #expect(f.group.pendingChildCount == 0)
    }
    @Test func confirmedNativeResultSurvivesChildFinishFailureAndStopsNextStep() async throws {
        let f = try WorkspaceRunnerFixture(); f.failFinish = .layout
        let report = await f.run()
        #expect(report.receiptUncertain && report.entries[0].layout == .confirmed && report.entries[1].focus == .notExecuted)
        #expect(f.finishedParent == report && !f.events.contains("focus.1"))
    }
    @Test func confirmedLayoutsSurviveParentFinishFailure() async throws {
        let f = try WorkspaceRunnerFixture(); f.failParentFinish = true
        let report = await f.run()
        #expect(report.receiptUncertain && report.state == .interrupted && report.entries.allSatisfy { $0.layout == .confirmed })
    }
    @Test func parentIntentFailureClosesSessionWithNoChildOrEffects() async throws {
        let f = try WorkspaceRunnerFixture(); f.failParentBegin = true
        let report = await f.run()
        #expect(report.receiptUncertain && f.events == ["parentIntent","abandon","releaseParent","close"])
    }
    @Test func cancelDuringWriteRevokesImmediatelyAndWaitsForRealWorker() async throws {
        let f = try WorkspaceRunnerFixture(), gate = WorkspaceRunnerGate(); f.gate = gate
        let task = Task { await f.run() }
        try await gate.enteredWithinDeadline(); task.cancel()
        for _ in 0..<10 { await Task.yield() }
        #expect(!f.group.isCurrent && f.group.pendingChildCount == 1 && !f.events.contains("parentFinish") && !f.events.contains("close"))
        gate.release(); let report = await task.value
        #expect(report.entries[0].focus == .confirmed && report.entries[0].layout == .unknown && report.entries[1].focus == .notExecuted)
        #expect(f.group.pendingChildCount == 0 && f.events.suffix(3) == ["parentFinish","releaseParent","close"])
    }
    @Test func preciseFocusCancellationStopsBeforeAnyLayout() async throws {
        let f = try WorkspaceRunnerFixture(), gate = WorkspaceRunnerGate(); f.gate = gate; f.gatePhase = .focus
        let task = Task { await f.run() }; try await gate.enteredWithinDeadline(); f.group.revoke(); gate.release()
        let report = await task.value
        #expect(report.entries[0].focus == .unknown && report.entries.allSatisfy { $0.layout == .notExecuted })
    }
    @Test func eightEntriesHaveOneParentAndAtMostOneInFlightChild() async throws {
        let f = try WorkspaceRunnerFixture(count: 8)
        let report = await f.run()
        #expect(report.state == .succeeded && f.pending.count == 16 && f.group.pendingChildCount == 0)
        #expect(f.events.filter { $0 == "parentIntent" }.count == 1)
    }
    @Test func precancelledRunNeverOpensFactoryOrJournal() async throws {
        let f = try WorkspaceRunnerFixture(), gate = WorkspaceRunnerGate()
        let task = Task { await gate.wait(); return await f.run() }
        try await gate.enteredWithinDeadline(); task.cancel(); gate.release()
        let report = await task.value
        #expect(report.state == .cancelled && f.events.isEmpty)
    }
}
