import Foundation
import Testing
import AgentCore
@testable import AICore

private actor TokenChatTransport: AIHTTPTransport {
    var responses: [Data]
    var requests: [[String: JSONValue]] = []
    init(_ responses: [Data]) { self.responses = responses }
    func open(_ request: URLRequest) throws -> AIHTTPResponse {
        requests.append(try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody)))
        let bytes = responses.removeFirst()
        return .init(statusCode: 200, body: .init { $0.yield(bytes); $0.finish() })
    }
}
private actor TokenChatBroker: AgentToolRouting {
    var count = 0
    func definitions() -> [AIToolDefinition] { [CurrentTimeTool().definition] }
    func invoke(_ call: AIToolCall, allowed: Set<String>) -> String { count += 1; return "Synthetic time" }
}
@Suite struct AgentTokenChatTests {
    private func frame(_ value: String) -> Data { Data(("data: " + value + "\n\ndata: [DONE]\n\n").utf8) }
    private var tool: Data { frame(#"{"id":"synthetic-response","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"synthetic-call","type":"function","function":{"name":"current_time","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":5}}"#) }
    private var final: Data { frame(#"{"id":"synthetic-response","choices":[{"index":0,"delta":{"content":"Synthetic final"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":5}}"#) }
    private func provider(_ transport: TokenChatTransport) -> ChatCompletionsProvider {
        .init(configuration: .init(endpoint: URL(string: "https://synthetic.invalid/v1/chat/completions")!, model: "synthetic-model", maxOutputTokens: 64), apiKey: "", transport: transport)
    }
    @Test func chatCapsEachTurnAndPreservesToolCallMessages() async throws {
        let transport = TokenChatTransport([tool, final]), broker = TokenChatBroker()
        let runner = BoundedAgentRunner(provider: provider(transport), broker: broker, maxRunTokens: 30, perRequestOutputLimit: 25)
        for try await _ in runner.run(messages: [.init(role: "user", content: "Synthetic input")], allowedTools: ["current_time"]) { }
        let bodies = await transport.requests
        #expect(bodies.count == 2 && bodies[0]["max_completion_tokens"] == .number(25) && bodies[1]["max_completion_tokens"] == .number(20))
        let messages = try #require(bodies[1]["messages"]?.arrayValue)
        #expect(messages.count == 3 && messages[1].objectValue?["role"] == .string("assistant"))
        #expect(messages[1].objectValue?["tool_calls"]?.arrayValue?.first?.objectValue?["id"] == .string("synthetic-call"))
        #expect(messages[2].objectValue?["tool_call_id"] == .string("synthetic-call") && messages[2].objectValue?["content"] == .string("Synthetic time"))
        #expect(await broker.count == 1)
    }
    @Test func atThresholdNoPendingToolOrSecondRequestRuns() async throws {
        let transport = TokenChatTransport([tool]), broker = TokenChatBroker()
        let runner = BoundedAgentRunner(provider: provider(transport), broker: broker, maxRunTokens: 10, perRequestOutputLimit: 64)
        do {
            for try await _ in runner.run(messages: [.init(role: "user", content: "Synthetic input")], allowedTools: ["current_time"]) { }
            Issue.record("A threshold-bound run continued")
        } catch { #expect(error as? AgentRunTokenError == .thresholdReached) }
        let toolCount = await broker.count, requestCount = await transport.requests.count
        #expect(toolCount == 0 && requestCount == 1)
    }
}
