import Foundation
import Testing
import AgentCore
@testable import AICore

private func message(_ text: String, id: String = "msg_1", phase: String = "final_answer") -> JSONValue {
    .object(["type": .string("message"), "id": .string(id), "role": .string("assistant"), "status": .string("completed"),
        "phase": .string(phase), "content": .array([.object(["type": .string("output_text"), "text": .string(text), "annotations": .array([])])])])
}
private func reasoning(_ opaque: String) -> JSONValue {
    .object(["type": .string("reasoning"), "id": .string("rs_1"), "summary": .array([]), "encrypted_content": .string(opaque)])
}
private func call(_ id: String = "call_1") -> JSONValue {
    .object(["type": .string("function_call"), "id": .string("fc_" + id), "call_id": .string(id), "name": .string("current_time"), "arguments": .string("{}")])
}
private func turn(_ output: [JSONValue], id: String = "resp_1", terminal: String = "completed", reason: String = "max_output_tokens", usage: Bool = true) throws -> Data {
    var sequence = 0, result = Data()
    func append(_ type: String, _ fields: [String: JSONValue]) throws {
        var value = fields; value["type"] = .string(type); value["sequence_number"] = .number(Double(sequence)); sequence += 1
        result.append(Data("data: ".utf8)); result.append(try JSONEncoder().encode(value)); result.append(Data("\n\n".utf8))
    }
    try append("response.created", ["response": .object(["id": .string(id)])])
    for (index, item) in output.enumerated() {
        var added = item.objectValue!
        if added["type"] == .string("reasoning") { added["encrypted_content"] = .string("opaque-partial-never-replay") }
        try append("response.output_item.added", ["output_index": .number(Double(index)), "item": .object(added)])
        try append("response.output_item.done", ["output_index": .number(Double(index)), "item": item])
    }
    if terminal != "missing" {
        var response: [String: JSONValue] = ["id": .string(id), "status": .string(terminal), "output": .array(output)]
        if usage { response["usage"] = .object(["input_tokens": .number(17), "output_tokens": .number(9), "output_tokens_details": .object(["reasoning_tokens": .number(6)])]) }
        if terminal == "incomplete" { response["incomplete_details"] = .object(["reason": .string(reason)]) }
        try append("response." + terminal, ["response": .object(response)])
    }
    return result
}
private actor ResponsesTransport: AIHTTPTransport {
    var turns: [Data]
    var requests: [[String: JSONValue]] = []
    init(_ turns: [Data]) { self.turns = turns }
    func open(_ request: URLRequest) async throws -> AIHTTPResponse {
        requests.append(try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody)))
        guard !turns.isEmpty else { throw AIProviderError.invalidRequest }
        let bytes = turns.removeFirst()
        return .init(statusCode: 200, body: .init { continuation in
            // 任意UTF-8分片，最终snapshot仍由production parser组装。
            for offset in stride(from: 0, to: bytes.count, by: 517) { continuation.yield(bytes.subdata(in: offset..<min(offset + 517, bytes.count))) }
            continuation.finish()
        })
    }
    func bodies() -> [[String: JSONValue]] { requests }
}
private actor CountingBroker: AgentToolRouting {
    var calls: [String] = []
    func definitions() -> [AIToolDefinition] { [CurrentTimeTool().definition] }
    func invoke(_ call: AIToolCall, allowed: Set<String>) throws -> String {
        #expect(allowed == ["current_time"]); calls.append(call.id); return "synthetic-time-" + call.id
    }
    func count() -> Int { calls.count }
}
private actor HeldResponsesTransport: AIHTTPTransport {
    let bytes: Data
    var opened = false
    var drained = false
    init(_ bytes: Data) { self.bytes = bytes }
    func open(_ request: URLRequest) -> AIHTTPResponse {
        opened = true
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(bytes)
        return .init(statusCode: 200, body: body, cancel: { continuation.finish(throwing: CancellationError()) },
            waitForCompletion: { await self.finishDrain() })
    }
    func finishDrain() { drained = true }
    func state() -> (Bool, Bool) { (opened, drained) }
}
private func provider(_ transport: any AIHTTPTransport, recorder: AIUsageRecorder? = nil) -> ResolvedAIProvider {
    .init(configuration: .init(endpoint: URL(string: "https://api.openai.com/v1/responses")!, model: "gpt-6.2-sol",
        requestProtocol: .responses, reasoningEffort: "low", maxOutputTokens: 4096), apiKey: "", transport: transport, usageRecorder: recorder)
}

@Suite struct ResponsesTests {
    @Test func threeTurnsPreserveExactOpaqueOrderAndPhaseWithCallIDs() async throws {
        let transport = ResponsesTransport([try turn([reasoning("opaque-final-1"), message("private commentary", id: "msg_c", phase: "commentary"), call()]),
            try turn([reasoning("opaque-final-2"), call("call_2")], id: "resp_2"), try turn([message("你好 final 🌏")], id: "resp_3")])
        let broker = CountingBroker(), recorder = AIUsageRecorder()
        let runner = BoundedAgentRunner(provider: provider(transport, recorder: recorder), broker: broker)
        var text = "", completed = 0, usage: [AIUsage] = []
        for try await event in runner.run(messages: [.init(role: "system", content: "synthetic rules"), .init(role: "user", content: "synthetic input")], allowedTools: ["current_time"]) {
            switch event { case .text(let s): text += s; case .completed: completed += 1; case .usage(let u): usage.append(u); default: break }
        }
        let toolCount = await broker.count()
        #expect(text == "你好 final 🌏" && completed == 1 && toolCount == 2)
        #expect(usage.count == 3 && usage.allSatisfy { $0.inputTokens == 17 && $0.outputTokens == 9 })
        let bodies = await transport.bodies()
        #expect(bodies.count == 3)
        for body in bodies {
            #expect(body["store"] == .bool(false) && body["background"] == .bool(false) && body["truncation"] == .string("disabled"))
            #expect(body["previous_response_id"] == nil && body["conversation"] == nil && body["messages"] == nil)
            #expect(body["max_output_tokens"] == .number(4096) && body["reasoning"] == .object(["effort": .string("low")]))
            #expect(body["tools"]?.arrayValue?.first?.objectValue?["name"] == .string("current_time"))
            #expect(body["tools"]?.arrayValue?.first?.objectValue?["strict"] == .bool(false))
        }
        let second = try #require(bodies[1]["input"]?.arrayValue)
        #expect(second[2].objectValue?["encrypted_content"] == .string("opaque-final-1"))
        #expect(second[3].objectValue?["phase"] == .string("commentary"))
        #expect(second[4].objectValue?["call_id"] == .string("call_1"))
        #expect(second[5] == .object(["type": .string("function_call_output"), "call_id": .string("call_1"), "output": .string("synthetic-time-call_1")]))
        let third = try #require(bodies[2]["input"]?.arrayValue)
        #expect(Array(third.prefix(second.count)) == second)
        let summary = await recorder.closeAndSnapshot()
        #expect(summary.calls.count == 3)
        let publicBytes = try JSONEncoder().encode(summary)
        #expect(!String(decoding: publicBytes, as: UTF8.self).contains("opaque-final"))
    }
    @Test(arguments: ["missing", "incomplete", "failed"])
    func toolsCannotRunWithoutSuccessfulTerminal(_ terminal: String) async throws {
        let transport = ResponsesTransport([try turn([reasoning("opaque-secret"), call()], terminal: terminal)])
        let broker = CountingBroker(), recorder = AIUsageRecorder()
        let runner = BoundedAgentRunner(provider: provider(transport, recorder: recorder), broker: broker)
        var failed = false
        do { for try await _ in runner.run(messages: [.init(role: "user", content: "synthetic")], allowedTools: ["current_time"]) {} }
        catch { failed = true }
        let toolCount = await broker.count()
        #expect(failed && toolCount == 0)
        let recorded = await recorder.closeAndSnapshot()
        #expect(recorded.calls.count == 1)
        if terminal != "missing" { #expect(recorded.calls.first?.usage?.outputTokens == 9) }
    }
    @Test func largeFinalItemsUseResponsesBudgetAndOrdinaryTextNeverAdvertisesTools() async throws {
        let text = String(repeating: "x", count: 307_200) + "中文"
        let transport = ResponsesTransport([try turn([message(text)])])
        var result = ""
        for try await event in provider(transport).stream(.init(messages: [.init(role: "user", content: "synthetic")])) {
            if case .text(let s) = event { result += s }
        }
        #expect(result == text)
        let body = try #require(await transport.bodies().first)
        #expect(body["tools"] == .array([]) && body["tool_choice"] == .string("none"))
    }
    @Test func forgedToolOutputsAndReuseAfterCloseNeverOpenAnotherRequest() async throws {
        let transport = ResponsesTransport([try turn([call()])])
        let conversation = provider(transport).makeConversation()
        for try await _ in await conversation.stream(.initial(.init(messages: [.init(role: "user", content: "synthetic")], tools: [CurrentTimeTool().definition]))) {}
        do {
            for try await _ in await conversation.stream(.toolOutputs([.init(callID: "fc_call_1", output: "forged")])) {}
            Issue.record("Forged call ID was accepted")
        } catch { #expect(error as? AIProviderError == .invalidRequest) }
        await conversation.close()
        do { for try await _ in await conversation.stream(.initial(.init(messages: [.init(role: "user", content: "again")]))) {}; Issue.record("Closed conversation reused") } catch {}
        #expect(await transport.bodies().count == 1)
    }
    @Test func sameProviderCreatesIndependentConversations() async throws {
        let transport = ResponsesTransport([try turn([message("first")]), try turn([message("second")])])
        let service = provider(transport)
        for input in ["owned-A", "owned-B"] {
            for try await _ in service.stream(.init(messages: [.init(role: "user", content: input)])) {}
        }
        let bodies = await transport.bodies()
        #expect(bodies.allSatisfy { $0["input"]?.arrayValue?.count == 1 })
        #expect(!String(decoding: try JSONEncoder().encode(bodies[1]), as: UTF8.self).contains("owned-A"))
    }
    @Test func incompatibleDirectProviderNeverOpensTransport() async throws {
        let transport = ResponsesTransport([])
        let config = AIProviderConfiguration(endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, model: "gpt-6.2-sol")
        let service = ResolvedAIProvider(configuration: config, apiKey: "", transport: transport)
        do {
            for try await _ in service.stream(.init(messages: [.init(role: "user", content: "synthetic")], tools: [CurrentTimeTool().definition])) {}
            Issue.record("Incompatible Chat tools accepted")
        } catch { #expect(error as? AIModelSettingsError == .toolsRequireResponses) }
        #expect(await transport.bodies().isEmpty)
    }
    @Test func cancellationAfterFinalToolItemStillDrainsWithoutInvokingBroker() async throws {
        let transport = HeldResponsesTransport(try turn([reasoning("opaque-cancelled"), call()], terminal: "missing"))
        let broker = CountingBroker(), recorder = AIUsageRecorder()
        let runner = BoundedAgentRunner(provider: provider(transport, recorder: recorder), broker: broker)
        let task = Task { for try await _ in runner.run(messages: [.init(role: "user", content: "synthetic cancel")], allowedTools: ["current_time"]) {} }
        for _ in 0..<1000 {
            if await transport.state().0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await transport.state().0)
        task.cancel(); _ = await task.result
        let state = await transport.state()
        let toolCount = await broker.count()
        #expect(state.1 && toolCount == 0)
        let recorded = await recorder.closeAndSnapshot()
        #expect(recorded.calls.count == 1 && recorded.calls.first?.outcome == .cancelled)
        #expect(!String(decoding: try JSONEncoder().encode(recorded), as: UTF8.self).contains("opaque-cancelled"))
    }
    @Test(arguments: ["content_filter", "max_output_tokens", "steered"])
    func incompleteReasonAndKnownUsageArePreserved(_ reason: String) async throws {
        let transport = ResponsesTransport([try turn([message("partial")], terminal: "incomplete", reason: reason)])
        let recorder = AIUsageRecorder()
        do {
            for try await _ in provider(transport, recorder: recorder).stream(.init(messages: [.init(role: "user", content: "synthetic")])) {}
            Issue.record("Incomplete response succeeded")
        } catch {
            let expected: AIProviderError = reason == "content_filter" ? .contentFiltered : (reason == "max_output_tokens" ? .tokenLimit : .truncatedStream)
            #expect(error as? AIProviderError == expected)
        }
        let recorded = await recorder.closeAndSnapshot()
        #expect(recorded.calls.first?.usage?.outputTokens == 9 && recorded.calls.first?.outcome == .failed)
    }
    @Test func duplicateSequenceAndUnknownOutputTypesAreNotAccepted() throws {
        var decoder = ResponsesStreamDecoder(allowed: ["current_time"], attempt: UUID())
        let created = #"{"type":"response.created","sequence_number":1,"response":{"id":"resp_synthetic"}}"#
        _ = try decoder.consume(created)
        #expect(throws: AIProviderError.malformedEvent) { try decoder.consume(created) }
        #expect(throws: AIProviderError.unexpectedToolCall) {
            try ResponsesReplayItem.normalize(.object(["type": .string("web_search_call"), "id": .string("ws_1")]), allowed: ["current_time"])
        }
        var asyncCall = call().objectValue!; asyncCall["async"] = .bool(true)
        #expect(throws: AIProviderError.unexpectedToolCall) { try ResponsesReplayItem.normalize(.object(asyncCall), allowed: ["current_time"]) }
    }
}
