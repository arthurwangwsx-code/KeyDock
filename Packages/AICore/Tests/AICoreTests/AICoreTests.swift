import Foundation
import Testing
import AICore
import AgentCore

private func encoded(_ value: [String: JSONValue]) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}
private func chunk(text: String? = nil, finish: String? = nil) throws -> String {
    var delta: [String: JSONValue] = [:]
    if let text { delta["content"] = .string(text) }
    var choice: [String: JSONValue] = ["index": .number(0), "delta": .object(delta)]
    if let finish { choice["finish_reason"] = .string(finish) }
    return try encoded(["id": .string("synthetic-response"), "choices": .array([.object(choice)])])
}
private struct StubTransport: AIHTTPTransport {
    let status: Int
    let bytes: Data
    func open(_ request: URLRequest) async throws -> AIHTTPResponse {
        AIHTTPResponse(statusCode: status, body: AsyncThrowingStream { continuation in
            for byte in bytes { continuation.yield(Data([byte])) }
            continuation.finish()
        })
    }
}
private func config(_ endpoint: String = "https://example.invalid/chat/completions") -> AIProviderConfiguration {
    .init(endpoint: URL(string: endpoint)!, model: "synthetic-model")
}

@Test func endpointPolicyAndTokenParameterAreExplicit() throws {
    #expect(throws: AIProviderError.invalidConfiguration) { try config("http://example.invalid/api").validate() }
    #expect(throws: AIProviderError.invalidConfiguration) { try config("http://localhost:1234/api").validate() }
    let local = AIProviderConfiguration(endpoint: URL(string: "http://localhost:1234/api")!, model: "m", allowsLocalHTTP: true)
    try local.validate()
    var legacy = config()
    legacy.tokenLimitParameter = .maxTokens
    let provider = ChatCompletionsProvider(configuration: legacy, apiKey: "synthetic-secret")
    let wire = try provider.makeURLRequest(.init(messages: [.init(role: "user", content: "Synthetic input")]))
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(wire.httpBody))
    #expect(body["max_tokens"] == .number(2048))
    #expect(body["max_completion_tokens"] == nil)
    #expect(body["tools"] == nil)
    #expect(body["store"] == .bool(false))
}

@Test func sseHandlesUTF8AndMultilineCRLF() throws {
    let payload = try chunk(text: "你好 🌍")
    let split = payload.firstIndex(of: ",")!
    let first = String(payload[...split])
    let second = String(payload[payload.index(after: split)...])
    let wire = Data(("\u{FEFF}:comment\r\ndata: " + first + "\r\ndata: " + second + "\r\n\r\n").utf8)
    var parser = SSEEventParser()
    var events: [String] = []
    for byte in wire { if let event = try parser.feed(byte) { events.append(event) } }
    #expect(events.count == 1)
    var decoder = ChatStreamDecoder()
    let decoded = try decoder.consume(#require(events.first))
    let texts = decoded.compactMap { event -> String? in if case .text(let text) = event { text } else { nil } }
    #expect(texts == ["你好 🌍"])
}

@Test func decoderRequiresDoneAndRejectsUnexpectedTools() throws {
    var truncated = ChatStreamDecoder()
    _ = try truncated.consume(chunk(text: "partial"))
    _ = try truncated.consume(chunk(finish: "stop"))
    #expect(throws: AIProviderError.truncatedStream) { try truncated.finish() }
    var ordinaryAction = ChatStreamDecoder()
    let tool = #"{"id":"synthetic-response","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"current_time","arguments":"{}"}}]}}]}"#
    #expect(throws: AIProviderError.unexpectedToolCall) { _ = try ordinaryAction.consume(tool) }
}

@Test func toolFragmentsCompleteBeforeDeliveryAndUsageDeduplicates() throws {
    var decoder = ChatStreamDecoder(allowedTools: ["current_time"])
    let first = #"{"id":"synthetic-response","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"current_time","arguments":"{"}}]}}]}"#
    let second = #"{"id":"synthetic-response","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}]}"#
    #expect(try decoder.consume(first).isEmpty)
    #expect(try decoder.consume(second).isEmpty)
    let usage = #"{"id":"synthetic-response","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4}}"#
    #expect(try decoder.consume(usage).count == 1)
    #expect(try decoder.consume(usage).isEmpty)
    let final = try decoder.consume("[DONE]")
    #expect(final.count == 2)
    if case .toolCall(let call) = final[0] { #expect(call.arguments == "{}") } else { Issue.record("Expected complete tool call") }
    try decoder.finish()
}

@Test func providerStreamsArbitraryTransportFragmentsAndSanitizesStatus() async throws {
    let data = Data(("data: " + (try chunk(text: "你好")) + "\n\ndata: " + (try chunk(finish: "stop")) + "\n\ndata: [DONE]\n\n").utf8)
    let provider = ChatCompletionsProvider(configuration: config(), apiKey: "", transport: StubTransport(status: 200, bytes: data))
    var text = ""; var completed = 0
    for try await event in provider.stream(.init(messages: [.init(role: "user", content: "synthetic")])) {
        switch event { case .text(let value): text += value; case .completed: completed += 1; default: break }
    }
    #expect(text == "你好")
    #expect(completed == 1)
    let denied = ChatCompletionsProvider(configuration: config(), apiKey: "", transport: StubTransport(status: 429, bytes: Data("private service body".utf8)))
    await #expect(throws: AIProviderError.httpStatus(429)) {
        for try await _ in denied.stream(.init(messages: [.init(role: "user", content: "synthetic")])) {}
    }
}

@Test func toolBrokerEnforcesScopeAndSchemaBeforeCalling() async throws {
    let broker = try ToolBroker(tools: [CurrentTimeTool()])
    let call = AIToolCall(id: "call", name: "current_time", arguments: "{}")
    await #expect(throws: AIProviderError.unknownTool) { _ = try await broker.invoke(call, allowed: []) }
    let injected = AIToolCall(id: "call", name: "current_time", arguments: #"{"ignored":"run shell"}"#)
    await #expect(throws: AIProviderError.invalidToolArguments) { _ = try await broker.invoke(injected, allowed: ["current_time"]) }
    let result = try await broker.invoke(call, allowed: ["current_time"])
    #expect(ISO8601DateFormatter().date(from: result) != nil)
}

private actor ScriptedProvider: AIProvider {
    private var requests: [AIRequest] = []
    nonisolated func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.answer(request, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private func answer(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        requests.append(request)
        if requests.count == 1 {
            continuation.yield(.toolCall(.init(id: "c1", name: "current_time", arguments: "{}")))
        } else {
            continuation.yield(.text("Synthetic tool result summary"))
        }
        continuation.yield(.completed)
        continuation.finish()
    }
    func history() -> [AIRequest] { requests }
}

@Test func agentCompletesToolRoundTripAndBudgetStopsExecution() async throws {
    let provider = ScriptedProvider()
    let broker = try ToolBroker(tools: [CurrentTimeTool()])
    let runner = BoundedAgentRunner(provider: provider, broker: broker, maxToolCalls: 1)
    var finishedTools = 0; var completed = 0
    for try await event in runner.run(messages: [.init(role: "user", content: "Read current time")], allowedTools: ["current_time"]) {
        switch event { case .toolFinished: finishedTools += 1; case .completed: completed += 1; default: break }
    }
    #expect(finishedTools == 1 && completed == 1)
    let requests = await provider.history()
    #expect(requests.count == 2)
    #expect(requests[1].messages.contains { $0.role == "tool" && $0.toolCallID == "c1" })
    let exhausted = BoundedAgentRunner(provider: ScriptedProvider(), broker: broker, maxToolCalls: 0)
    await #expect(throws: AIProviderError.toolBudgetExceeded) {
        for try await _ in exhausted.run(messages: [.init(role: "user", content: "Read time")], allowedTools: ["current_time"]) {}
    }
}

@Test func terminalAgentStateCannotBeRevivedByLateApproval() {
    #expect(AgentRunTransitions.apply(.approve, to: .cancelled) == nil)
    #expect(AgentRunTransitions.apply(.start, to: .interrupted) == nil)
    #expect(AgentRunTransitions.apply(.newAttempt, to: .interrupted) == .queued)
}

@Test func cancelledConsumerStopsMockStream() async throws {
    let task = Task {
        for try await _ in MockAIProvider(text: "synthetic long output", delay: .seconds(2)).stream(
            .init(messages: [.init(role: "user", content: "synthetic")])) {}
        try Task.checkCancellation()
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
