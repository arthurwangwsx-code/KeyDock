import Foundation
import Testing
import AgentCore
@testable import AICore

private actor UsageDrainGate {
    var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if released { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { released = true; let ready = waiters; waiters.removeAll(); for waiter in ready { waiter.resume() } }
}
private actor UsageCompletionFlag { var completed = false; func finish() { completed = true } }
private actor UsageMemoryTransport: AIHTTPTransport {
    let responses: [Data]
    let holdOpen: Bool
    let drain: UsageDrainGate?
    private(set) var opens = 0
    init(_ responses: [Data], holdOpen: Bool = false, drain: UsageDrainGate? = nil) { self.responses = responses; self.holdOpen = holdOpen; self.drain = drain }
    func open(_ request: URLRequest) async throws -> AIHTTPResponse {
        let index = opens; opens += 1
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(responses[min(index, responses.count - 1)])
        if !holdOpen { continuation.finish() }
        let drain = drain
        return .init(statusCode: 200, body: body, cancel: { continuation.finish(throwing: CancellationError()) }, waitForCompletion: { if let drain { await drain.wait() } })
    }
}

@Suite struct AIRequestUsageTests {
    @Test(arguments: [AIRequestProtocol.chatCompletions, .responses], [false, true])
    func validatedTerminalIsVisibleWhileTransportDrains(_ requestProtocol: AIRequestProtocol, cancelAfterTerminal: Bool) async throws {
        let drain = UsageDrainGate(), recorder = AIUsageRecorder()
        let responses = event(#"{"type":"response.created","sequence_number":0,"response":{"id":"synthetic"}}"#)
            + event(#"{"type":"response.completed","sequence_number":1,"response":{"id":"synthetic","status":"completed","output":[],"usage":{"input_tokens":12,"output_tokens":3}}}"#)
        let transport = UsageMemoryTransport([requestProtocol == .responses ? responses : complete], drain: drain)
        let configuration = requestProtocol == .responses
            ? AIProviderConfiguration(endpoint: URL(string: "https://api.openai.com/v1/responses")!, model: "gpt-6.2-sol", requestProtocol: .responses)
            : AIProviderConfiguration(endpoint: URL(string: "https://example.com/synthetic")!, model: "synthetic-model")
        let service = ResolvedAIProvider(configuration: configuration, apiKey: "", transport: transport, usageRecorder: recorder)
        let stream = service.stream(request)
        let consumer = Task {
            var completed = 0
            for try await event in stream { if case .completed = event { completed += 1 } }
            return completed
        }
        do {
            try await eventually { await drain.entered }
            let recorded = try #require(recorder.snapshot().calls.first)
            #expect(recorded.outcome == .succeeded && recorded.finishedAt != nil)
            #expect(recorded.usage?.inputTokens == 12 && recorded.usage?.outputTokens == 3)
            #expect(!recorded.hasUnknownUsage && !recorder.isClosed)
            if cancelAfterTerminal {
                consumer.cancel()
                let terminal = await consumer.result
                if case .success(let count) = terminal { #expect(count == 0) }
            }
            await drain.release()
            if !cancelAfterTerminal { #expect(try await consumer.value == 1) }
            #expect(await recorder.closeAndSnapshot().calls == [recorded])
        } catch {
            consumer.cancel()
            await drain.release()
            throw error
        }
    }
    @Test func invalidAndSealedRequestsNeverReachTransport() async throws {
        let transport = UsageMemoryTransport([complete]), recorder = AIUsageRecorder()
        let service = provider(transport, recorder: recorder)
        do { for try await _ in service.stream(.init(messages: [])) { }; Issue.record("Invalid request succeeded") } catch { }
        let first = await recorder.closeAndSnapshot(); #expect(first.calls.isEmpty)
        do { for try await _ in service.stream(request) { }; Issue.record("Sealed request succeeded") } catch { }
        #expect(await transport.opens == 0)
    }
    @Test func successfulFinishAndUnconsumedEventsStillRecordOneActualAttempt() async throws {
        let transport = UsageMemoryTransport([complete]), recorder = AIUsageRecorder()
        let stream = provider(transport, recorder: recorder).stream(request)
        try await eventually { recorder.snapshot().calls.first?.usage != nil }
        let recorded = await recorder.closeAndSnapshot()
        #expect(recorded.calls.count == 1 && recorded.calls.first?.outcome == .succeeded)
        #expect(recorded.calls.first?.usage?.inputTokens == 12 && recorded.calls.first?.usage?.outputTokens == 3)
        var events = 0; for try await _ in stream { events += 1 }; #expect(events > 0)
        let bytes = String(decoding: try JSONEncoder().encode(recorded), as: UTF8.self)
        #expect(!bytes.contains("synthetic-private-query") && !bytes.contains("synthetic-input-sentinel") && !bytes.contains("synthetic-key-sentinel"))
    }
    @Test(arguments: ["length", "content_filter"])
    func validUsageInFailingPayloadIsRetained(_ reason: String) async throws {
        let payload = #"{"id":"synthetic-response","choices":[{"index":0,"delta":{},"finish_reason":"REASON"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#.replacingOccurrences(of: "REASON", with: reason)
        let recorder = AIUsageRecorder(), transport = UsageMemoryTransport([event(payload)])
        do { for try await _ in provider(transport, recorder: recorder).stream(request) { }; Issue.record("Expected provider failure") } catch { }
        let recorded = await recorder.closeAndSnapshot()
        #expect(recorded.calls.first?.usage?.inputTokens == 12 && recorded.calls.first?.usage?.outputTokens == 3)
        #expect(recorded.calls.first?.outcome == .failed && recorded.calls.first?.hasUnknownUsage == true)
    }
    @Test func cancelledConsumerRetainsKnownUsageAndWaitsForOwnedBodyDrain() async throws {
        let drain = UsageDrainGate(), completion = UsageCompletionFlag()
        let transport = UsageMemoryTransport([event(#"{"id":"synthetic-response","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#)], holdOpen: true, drain: drain)
        let recorder = AIUsageRecorder(), service = provider(transport, recorder: recorder)
        let consumer = Task { do { for try await _ in service.stream(request) { try Task.checkCancellation() } } catch { } }
        do {
        try await eventually { recorder.snapshot().calls.first?.usage != nil }
        consumer.cancel(); await consumer.value
        try await eventually { await drain.entered }
        let close = Task { let value = await recorder.closeAndSnapshot(); await completion.finish(); return value }
        try await eventually { recorder.isClosed }
        #expect(!(await completion.completed))
        #expect(recorder.beginWorker() == nil)
        await drain.release()
        let recorded = await close.value
        #expect(recorded.calls.first?.outcome == .cancelled && recorded.calls.first?.usage?.inputTokens == 12)
        let completed = await completion.completed
        #expect(recorded.calls.first?.hasUnknownUsage == true && completed)
        } catch {
            consumer.cancel(); await drain.release(); await consumer.value; throw error
        }
    }
    @Test func agentTurnsHaveDistinctAttemptsWithoutDuplicateUnknownPlaceholders() async throws {
        let first = event(#"{"id":"same-response","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"synthetic-call","type":"function","function":{"name":"current_time","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":1}}"#) + Data("data: [DONE]\n\n".utf8)
        let recorder = AIUsageRecorder(), service = provider(UsageMemoryTransport([first, complete]), recorder: recorder)
        let broker = try ToolBroker(tools: [CurrentTimeTool()]), runner = BoundedAgentRunner(provider: service, broker: broker, maxTurns: 3)
        var unknown = 0
        for try await event in runner.run(messages: request.messages, allowedTools: ["current_time"]) { if case .usageUnknown = event { unknown += 1 } }
        let recorded = await recorder.closeAndSnapshot()
        #expect(recorded.calls.count == 2 && Set(recorded.calls.map(\.attemptID)).count == 2 && unknown == 0)
        #expect(recorded.calls.allSatisfy { $0.outcome == .succeeded && !$0.hasUnknownUsage })
        #expect(recorded.calls.compactMap { $0.usage?.inputTokens }.reduce(0, +) == 17)
    }
    @Test func workflowForkKeepsFrozenPriceWithoutCopyingPreviousCalls() async throws {
        let url = URL(string: "https://example.com/synthetic?synthetic-private-query")!
        let rate = AIRateDefinition(endpointFingerprint: AIServiceIdentity.fingerprint(url), model: "synthetic-model", currency: "USD", inputPerMillion: "2", outputPerMillion: "4")
        let recorder = AIUsageRecorder(rate: .init(rate: rate)), service = provider(UsageMemoryTransport([complete]), recorder: recorder)
        for try await _ in service.stream(request) { }
        _ = await recorder.closeAndSnapshot()
        let fork = service.withFreshUsageRecorder()
        for try await _ in fork.stream(request) { }
        let next = await fork.usageRecorder?.closeAndSnapshot()
        #expect(recorder.snapshot().calls.count == 1 && next?.calls.count == 1)
        #expect(recorder.snapshot().calls.first?.attemptID != next?.calls.first?.attemptID)
        #expect(next?.calls.first?.rate?.rate == rate && recorder.snapshot().calls.first?.rate?.rate == rate)
    }
    private var request: AIRequest { .init(messages: [.init(role: "user", content: "synthetic-input-sentinel")]) }
    private var complete: Data { event(#"{"id":"same-response","choices":[{"index":0,"delta":{"content":"Synthetic result"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#) + Data("data: [DONE]\n\n".utf8) }
    private func event(_ payload: String) -> Data { Data(("data: " + payload + "\n\n").utf8) }
    private func provider(_ transport: any AIHTTPTransport, recorder: AIUsageRecorder) -> ChatCompletionsProvider {
        .init(configuration: .init(endpoint: URL(string: "https://example.com/synthetic?synthetic-private-query")!, model: "synthetic-model"), apiKey: "synthetic-key-sentinel", transport: transport, usageRecorder: recorder)
    }
    private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) } while ContinuousClock.now < deadline
        throw URLError(.timedOut)
    }
}
