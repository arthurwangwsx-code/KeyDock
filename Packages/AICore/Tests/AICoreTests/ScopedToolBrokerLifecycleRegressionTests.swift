import Foundation
import Testing
import AICore
import AgentCore
import ExecutionCore

// 原创合成回归建议；未编译。由主 Agent 串行集成到 AICoreTests。
private enum BrokerRegressionFailure: Error { case remoteDisconnected, gateDeadline }

private actor BrokerRegressionProbe {
    private(set) var dispatches = 0
    private(set) var approvals = 0
    private(set) var closeStarted = false
    private(set) var closeReturned = false
    private(set) var startsObserved = 0
    func dispatched() { dispatches += 1 }
    func approved() { approvals += 1 }
    func closing() { closeStarted = true }
    func closed() { closeReturned = true }
    func observedStart() { startsObserved += 1 }
}

private actor BrokerRegressionGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var released = false
    private(set) var entered = false

    func hold() async throws {
        entered = true
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()) }
                else if released { c.resume() }
                else { continuation = c }
            }
        } onCancel: { Task { await self.cancelWait() } }
    }

    func release() {
        released = true
        let c = continuation; continuation = nil
        c?.resume()
    }

    private func cancelWait() {
        let c = continuation; continuation = nil
        c?.resume(throwing: CancellationError())
    }
}

private struct BrokerRegressionProvider: AIProvider {
    let events: [AIEvent]
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@Suite(.serialized)
struct ScopedToolBrokerLifecycleRegressionTests {
    private let name = "regression_effect"

    private func fixture() throws -> (URL, InvocationStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keydock-agent-regression-" + UUID().uuidString)
        return (directory, try InvocationStore(directory: directory))
    }

    private func effect(
        _ operation: @escaping @Sendable ([String: JSONValue], UUID) async throws -> String
    ) -> ScopedAITool {
        ScopedAITool(
            definition: .init(name: name, description: "Synthetic regression effect", parameters: [
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": .bool(false)
            ]),
            effects: [.writeFile],
            resource: .exact(namespace: "synthetic.regression", identifier: "temporary-fixture"),
            approvalSummary: "Synthetic effect; no external service or personal files",
            invoke: operation
        )
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw BrokerRegressionFailure.gateDeadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func drainingClosePreservesTheOwnedCallAndReturnsAfterItsReceipt() async throws {
        let (directory, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BrokerRegressionProbe(), gate = BrokerRegressionGate()
        let tool = effect { _, _ in
            await probe.dispatched()
            try await gate.hold()
            try Task.checkCancellation()
            return "Synthetic completed effect"
        }
        let broker = try ScopedToolBroker(runID: UUID(), tools: [tool], journal: journal) { _ in
            await probe.approved(); return true
        }
        let invocation = Task {
            try await broker.invoke(.init(id: "drain", name: name, arguments: "{}"), allowed: [name])
        }
        defer { invocation.cancel(); Task { await gate.release() } }
        try await waitUntil { await gate.entered }
        let closing = Task {
            await probe.closing()
            await broker.close(cancel: false)
            let receipts = await journal.list()
            await probe.closed()
            return receipts
        }
        try await waitUntil { await probe.closeStarted }
        await Task.yield()
        #expect(!(await probe.closeReturned))
        await gate.release()
        #expect(try await invocation.value == "Synthetic completed effect")
        let receiptsAtClose = await closing.value
        #expect(receiptsAtClose.count == 1 && receiptsAtClose[0].state == .succeeded)
        #expect(await probe.dispatches == 1)
        #expect(await probe.approvals == 1)
        await #expect(throws: CancellationError.self) {
            try await broker.invoke(.init(id: "after-close", name: name, arguments: "{}"), allowed: [name])
        }
        #expect(await journal.list().count == 1)
    }

    @Test func cancellingCloseDrainsDispatchedWorkAndRetainsUnknownOutcome() async throws {
        let (directory, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BrokerRegressionProbe(), gate = BrokerRegressionGate()
        let tool = effect { _, _ in
            await probe.dispatched()
            try await gate.hold()
            return "Unreachable after cancellation"
        }
        let broker = try ScopedToolBroker(runID: UUID(), tools: [tool], journal: journal) { _ in true }
        let invocation = Task {
            try await broker.invoke(.init(id: "cancel-owned", name: name, arguments: "{}"), allowed: [name])
        }
        defer { invocation.cancel(); Task { await gate.release() } }
        try await waitUntil { await gate.entered }
        await broker.close(cancel: true)
        await #expect(throws: CancellationError.self) { try await invocation.value }
        #expect(await probe.dispatches == 1)
        #expect(await broker.unknownInvocationCount() == 1)
        let receipts = await journal.list()
        #expect(receipts.count == 1 && receipts[0].state == .interrupted)
        #expect(receipts.first?.message == "agent.toolOutcomeUnknown")
    }

    @Test func throwAfterDispatchIsUnknownRatherThanFailureWithoutEffects() async throws {
        let (directory, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BrokerRegressionProbe()
        let tool = effect { _, id in
            let before = await journal.list()
            #expect(before.contains { $0.id == id && $0.state == .running })
            await probe.dispatched()
            throw BrokerRegressionFailure.remoteDisconnected
        }
        let broker = try ScopedToolBroker(runID: UUID(), tools: [tool], journal: journal) { _ in true }
        await #expect(throws: BrokerRegressionFailure.self) {
            try await broker.invoke(.init(id: "unknown", name: name, arguments: "{}"), allowed: [name])
        }
        await broker.close(cancel: false)
        #expect(await probe.dispatches == 1)
        #expect(await broker.unknownInvocationCount() == 1)
        let receipts = await journal.list()
        #expect(receipts.count == 1 && receipts[0].state == .interrupted)
        #expect(receipts.first?.message == "agent.toolOutcomeUnknown")
    }

    @Test func outputBudgetStopsBeforeToolStartApprovalIntentOrDispatch() async throws {
        let (directory, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BrokerRegressionProbe()
        let tool = effect { _, _ in await probe.dispatched(); return "Synthetic result" }
        let broker = try ScopedToolBroker(runID: UUID(), tools: [tool], journal: journal) { _ in
            await probe.approved(); return true
        }
        let provider = BrokerRegressionProvider(events: [
            .text("12345678"),
            .toolCall(.init(id: "over-budget", name: name, arguments: "{}")),
            .completed
        ])
        let runner = BoundedAgentRunner(provider: provider, broker: broker, maxOutputBytes: 8)
        await #expect(throws: AIProviderError.outputLimit) {
            for try await event in runner.run(messages: [.init(role: "user", content: "Synthetic request")], allowedTools: [name]) {
                if case .toolStarted = event { await probe.observedStart() }
            }
        }
        await broker.close(cancel: true)
        #expect(await probe.startsObserved == 0)
        #expect(await probe.approvals == 0)
        #expect(await probe.dispatches == 0)
        #expect(await journal.list().isEmpty)
        #expect(await broker.unknownInvocationCount() == 0)
    }

    @Test func toolCallBudgetStopsBeforeApprovalIntentOrDispatch() async throws {
        let (directory, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BrokerRegressionProbe()
        let tool = effect { _, _ in await probe.dispatched(); return "Synthetic result" }
        let broker = try ScopedToolBroker(runID: UUID(), tools: [tool], journal: journal) { _ in
            await probe.approved(); return true
        }
        let provider = BrokerRegressionProvider(events: [
            .toolCall(.init(id: "budget-zero", name: name, arguments: "{}")), .completed
        ])
        let runner = BoundedAgentRunner(provider: provider, broker: broker, maxToolCalls: 0)
        await #expect(throws: AIProviderError.toolBudgetExceeded) {
            for try await _ in runner.run(messages: [.init(role: "user", content: "Synthetic request")], allowedTools: [name]) {}
        }
        await broker.close(cancel: true)
        #expect(await probe.approvals == 0)
        #expect(await probe.dispatches == 0)
        #expect(await journal.list().isEmpty)
        #expect(await broker.unknownInvocationCount() == 0)
    }
}
