import Foundation

/// 仅在会话内驻留的允许输入投影；不可Codable导出或放入普通AIMessage。
enum ResponsesReplayItem: Equatable, Sendable {
    case message(JSONValue), reasoning(JSONValue), functionCall(JSONValue)
    var wire: JSONValue { switch self { case .message(let v), .reasoning(let v), .functionCall(let v): v } }
    var call: AIToolCall? {
        guard case .functionCall(let value) = self, let v = value.objectValue else { return nil }
        return .init(id: v["call_id"]!.stringValue!, name: v["name"]!.stringValue!, arguments: v["arguments"]!.stringValue!)
    }
    var visibleText: String {
        guard case .message(let value) = self, let v = value.objectValue,
              v["phase"]?.stringValue != "commentary" else { return "" }
        return (v["content"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined()
    }
    static func normalize(_ value: JSONValue, allowed: Set<String>) throws -> Self {
        guard let v = value.objectValue, let type = v["type"]?.stringValue, let id = v["id"]?.stringValue,
              !id.isEmpty, id.utf8.count <= 512 else { throw AIProviderError.malformedEvent }
        var out: [String: JSONValue] = ["type": .string(type), "id": .string(id)]
        switch type {
        case "message":
            guard v["role"]?.stringValue == "assistant", v["status"]?.stringValue == "completed",
                  let content = v["content"]?.arrayValue, content.count <= 64 else { throw AIProviderError.malformedEvent }
            out["role"] = .string("assistant"); out["status"] = .string("completed")
            if let phase = v["phase"], phase != .null {
                guard ["commentary", "final_answer"].contains(phase.stringValue ?? "") else { throw AIProviderError.malformedEvent }
                out["phase"] = phase
            }
            out["content"] = .array(try content.map { part in
                guard let p = part.objectValue else { throw AIProviderError.malformedEvent }
                if p["type"]?.stringValue == "refusal" { throw AIProviderError.contentFiltered }
                guard p["type"]?.stringValue == "output_text", let text = p["text"]?.stringValue,
                      text.utf8.count <= 1_048_576, (p["annotations"]?.arrayValue ?? []).isEmpty else { throw AIProviderError.malformedEvent }
                return .object(["type": .string("output_text"), "text": .string(text), "annotations": .array([])])
            })
            return .message(.object(out))
        case "reasoning":
            guard let summary = v["summary"]?.arrayValue, summary.count <= 64 else { throw AIProviderError.malformedEvent }
            out["summary"] = .array(try summary.map { value in
                guard let p = value.objectValue, p["type"]?.stringValue == "summary_text", let text = p["text"]?.stringValue else { throw AIProviderError.malformedEvent }
                return .object(["type": .string("summary_text"), "text": .string(text)])
            })
            if let encrypted = v["encrypted_content"], encrypted != .null {
                guard encrypted.stringValue != nil else { throw AIProviderError.malformedEvent }
                out["encrypted_content"] = encrypted
            }
            // 新协议可能返回raw reasoning content，首版不推测其重放合同。
            guard v["content"] == nil || v["content"] == .null || v["content"] == .array([]) else { throw AIProviderError.malformedEvent }
            return .reasoning(.object(out))
        case "function_call":
            guard let callID = v["call_id"]?.stringValue, !callID.isEmpty, callID.utf8.count <= 512,
                  let name = v["name"]?.stringValue, allowed.contains(name), let args = v["arguments"]?.stringValue,
                  args.utf8.count <= 65_536, v["status"] == nil || v["status"] == .null || v["status"]?.stringValue == "completed",
                  v["async"] == nil || v["async"] == .bool(false),
                  v["namespace"] == nil || v["namespace"] == .null,
                  v["caller"] == nil || v["caller"] == .null || v["caller"]?.objectValue?["type"] == .string("direct") else {
                throw AIProviderError.unexpectedToolCall
            }
            out["call_id"] = .string(callID); out["name"] = .string(name); out["arguments"] = .string(args)
            out["status"] = .string("completed")
            return .functionCall(.object(out))
        default: throw AIProviderError.unexpectedToolCall
        }
    }
}

struct ResponsesStreamDecoder: Sendable {
    let allowed: Set<String>
    let attempt: UUID
    var responseID: String?
    var sequence = -1
    var items: [Int: ResponsesReplayItem] = [:]
    var addedIDs: [Int: String] = [:]
    var latestUsage: AIUsage?
    var complete = false
    var retainedBytes = 0
    mutating func consume(_ payload: String) throws -> [AIEvent] {
        guard !complete, let data = payload.data(using: .utf8),
              let v = try? JSONDecoder().decode([String: JSONValue].self, from: data), let type = v["type"]?.stringValue,
              let number = v["sequence_number"]?.numberValue, number.isFinite, number.rounded() == number,
              number >= 0, number <= Double(Int32.max), Int(number) > sequence else { throw AIProviderError.malformedEvent }
        sequence = Int(number)
        switch type {
        case "response.created", "response.in_progress":
            guard let id = v["response"]?.objectValue?["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 512,
                  responseID == nil || responseID == id else { throw AIProviderError.malformedEvent }
            responseID = id; return []
        case "response.output_item.added":
            let index = try index(v)
            guard addedIDs[index] == nil, let id = v["item"]?.objectValue?["id"]?.stringValue, !id.isEmpty,
                  !addedIDs.values.contains(id) else { throw AIProviderError.malformedEvent }
            addedIDs[index] = id; return []
        case "response.output_item.done":
            let index = try index(v)
            guard items[index] == nil, let item = v["item"], addedIDs[index] == item.objectValue?["id"]?.stringValue else { throw AIProviderError.malformedEvent }
            let normalized = try ResponsesReplayItem.normalize(item, allowed: allowed)
            retainedBytes += try JSONEncoder().encode(normalized.wire).count
            guard retainedBytes <= 1_048_576 else { throw AIProviderError.outputLimit }
            items[index] = normalized
            let text = normalized.visibleText
            return text.isEmpty ? [] : [.text(text)]
        case "response.completed", "response.incomplete", "response.failed":
            guard let response = v["response"]?.objectValue, let id = response["id"]?.stringValue, id == responseID else { throw AIProviderError.malformedEvent }
            if let usage = response["usage"], usage != .null {
                guard let u = usage.objectValue else { throw AIProviderError.malformedEvent }
                func count(_ key: String) throws -> Int? {
                    guard let value = u[key], value != .null else { return nil }
                    guard let n = value.numberValue, n.isFinite, n.rounded() == n, n >= 0, n <= 1_000_000_000_000 else { throw AIProviderError.malformedEvent }
                    return Int(n)
                }
                latestUsage = .init(inputTokens: try count("input_tokens"), outputTokens: try count("output_tokens"), attemptID: attempt, responseID: id)
            }
            if type == "response.incomplete" {
                switch response["incomplete_details"]?.objectValue?["reason"]?.stringValue {
                case "max_output_tokens": throw AIProviderError.tokenLimit
                case "content_filter": throw AIProviderError.contentFiltered
                default: throw AIProviderError.truncatedStream
                }
            }
            if type == "response.failed" { throw AIProviderError.modelServiceError }
            guard response["status"]?.stringValue == "completed", let output = response["output"]?.arrayValue,
                  output.count == items.count, output.count == addedIDs.count else { throw AIProviderError.malformedEvent }
            for (index, item) in output.enumerated() {
                guard try ResponsesReplayItem.normalize(item, allowed: allowed) == items[index] else { throw AIProviderError.malformedEvent }
            }
            let calls = outputItems.compactMap(\.call)
            guard calls.count <= 16, Set(calls.map(\.id)).count == calls.count else { throw AIProviderError.malformedEvent }
            complete = true
            return (latestUsage.map { [.usage($0)] } ?? []) + calls.map(AIEvent.toolCall)
        case "error": throw AIProviderError.modelServiceError
        case "response.output_text.delta", "response.output_text.done", "response.content_part.added", "response.content_part.done",
             "response.function_call_arguments.delta", "response.function_call_arguments.done",
             "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
             "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done":
            let index = try index(v)
            guard addedIDs[index] != nil, items[index] == nil else { throw AIProviderError.malformedEvent }
            return [] // 仅发布最终item的可见文本；delta中的opaque／不完整参数绝不公开。
        default: throw AIProviderError.malformedEvent
        }
    }
    var outputItems: [ResponsesReplayItem] { items.keys.sorted().compactMap { items[$0] } }
    private func index(_ value: [String: JSONValue]) throws -> Int {
        guard let n = value["output_index"]?.numberValue, n.rounded() == n, (0..<128).contains(n) else { throw AIProviderError.malformedEvent }
        return Int(n)
    }
}

actor ResponsesAIConversation: AIConversation {
    let configuration: AIProviderConfiguration
    let apiKey: String
    let transport: any AIHTTPTransport
    let recorder: AIUsageRecorder?
    var history: [JSONValue] = []
    var request: AIRequest?
    var pending: Set<String> = []
    var worker: Task<Void, Never>?
    var closed = false
    init(configuration: AIProviderConfiguration, apiKey: String, transport: any AIHTTPTransport, recorder: AIUsageRecorder?) {
        self.configuration = configuration; self.apiKey = apiKey; self.transport = transport; self.recorder = recorder
    }
    func stream(_ input: AIConversationInput) async -> AsyncThrowingStream<AIEvent, any Error> {
        guard !closed, worker == nil else { return .init { $0.finish(throwing: AIProviderError.invalidRequest) } }
        do {
            switch input {
            case .initial(let value):
                guard request == nil, !value.messages.isEmpty, value.messages.count <= 128 else { throw AIProviderError.invalidRequest }
                history = try value.messages.map { message in
                    guard ["system", "developer", "user"].contains(message.role), message.toolCalls == nil, message.toolCallID == nil,
                          message.content.utf8.count <= 1_048_576 else { throw AIProviderError.invalidRequest }
                    return .object(["role": .string(message.role), "content": .array([.object(["type": .string("input_text"), "text": .string(message.content)])])])
                }
                request = value
            case .toolOutputs(let values, let cap):
                guard request != nil, !pending.isEmpty, values.count == pending.count,
                      Set(values.map(\.callID)) == pending else { throw AIProviderError.invalidRequest }
                guard cap.map({ (1...configuration.maxOutputTokens).contains($0) }) ?? true else { throw AIProviderError.invalidRequest }
                guard values.allSatisfy({ $0.output.utf8.count <= 1_048_576 }) else { throw AIProviderError.outputLimit }
                for value in values {
                    history.append(.object(["type": .string("function_call_output"), "call_id": .string(value.callID), "output": .string(value.output)]))
                }
                if let cap { request!.maxTokens = cap }
                pending = []
            }
            let wire = try makeRequest()
            let (stream, continuation) = AsyncThrowingStream<AIEvent, any Error>.makeStream()
            let task = Task { await perform(wire, continuation: continuation) }; worker = task
            continuation.onTermination = { @Sendable reason in if case .cancelled = reason { task.cancel() } }
            return stream
        } catch { closed = true; history = []; request = nil; return .init { $0.finish(throwing: error) } }
    }
    private func makeRequest() throws -> URLRequest {
        try configuration.validate()
        guard configuration.requestProtocol == .responses, let request, request.tools.count <= 16,
              Set(request.tools.map(\.name)).count == request.tools.count,
              !apiKey.contains("\n"), !apiKey.contains("\r") else { throw AIProviderError.invalidRequest }
        try AIModelCatalog.validate(configuration, requiresTools: !request.tools.isEmpty)
        let budget = request.maxTokens ?? configuration.maxOutputTokens
        guard (1...configuration.maxOutputTokens).contains(budget) else { throw AIProviderError.invalidRequest }
        guard try JSONEncoder().encode(history).count <= 1_048_576 else { throw AIProviderError.outputLimit }
        var body: [String: JSONValue] = ["model": .string(configuration.model), "input": .array(history), "stream": .bool(true),
            "store": .bool(false), "background": .bool(false), "truncation": .string("disabled"), "max_output_tokens": .number(Double(budget)),
            "tools": .array(request.tools.map { .object(["type": .string("function"), "name": .string($0.name),
                "description": .string($0.description), "parameters": .object($0.parameters), "strict": .bool(false)]) }),
            "tool_choice": .string(request.tools.isEmpty ? "none" : "auto"), "parallel_tool_calls": .bool(false)]
        if let effort = configuration.reasoningEffort { body["reasoning"] = .object(["effort": .string(effort)]) }
        let bytes = try JSONEncoder().encode(body)
        guard bytes.count <= 2_097_152 else { throw AIProviderError.outputLimit }
        var wire = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.timeout)
        wire.httpMethod = "POST"; wire.httpBody = bytes
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type"); wire.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { wire.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return wire
    }
    private func perform(_ wire: URLRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async {
        let owner = recorder?.beginWorker()
        var attempt: UUID?, outcome = AIRecordedCall.Outcome.failed
        defer {
            if let attempt { recorder?.finishAttempt(attempt, outcome: outcome) }
            if let owner { recorder?.endWorker(owner) }
            worker = nil
        }
        do {
            try Task.checkCancellation()
            if let recorder {
                guard let owner, let id = recorder.beginAttempt(worker: owner, configuration: configuration) else { throw CancellationError() }
                attempt = id
            } else { attempt = UUID() }
            let response = try await transport.open(wire)
            var decoder = ResponsesStreamDecoder(allowed: Set(request!.tools.map(\.name)), attempt: attempt!)
            do {
                try await withTaskCancellationHandler {
                    guard (200..<300).contains(response.statusCode) else { throw AIProviderError.httpStatus(response.statusCode) }
                    guard response.contentType?.lowercased().hasPrefix("text/event-stream") == true else { throw AIProviderError.invalidContentType }
                    var parser = SSEEventParser(maximumLineBytes: 2_097_152, maximumEventBytes: 2_097_152)
                    loop: for try await data in response.body {
                        try Task.checkCancellation()
                        for byte in data {
                            if let payload = try parser.feed(byte) {
                                let events = try decoder.consume(payload)
                                for event in events { if case .usage(let usage) = event { recorder?.observe(usage) }; continuation.yield(event) }
                                if decoder.complete { break loop }
                            }
                        }
                    }
                    guard decoder.complete else { throw AIProviderError.truncatedStream }
                } onCancel: { response.cancel() }
            } catch {
                if let usage = decoder.latestUsage { recorder?.observe(usage) }
                response.cancel(); await response.waitForCompletion(); throw error
            }
            // 提供方终态已核实；本地取消或会话历史超限仍保留这次调用的用量。
            outcome = .succeeded
            if let attempt { recorder?.finishAttempt(attempt, outcome: outcome) }
            response.cancel(); await response.waitForCompletion(); try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            history += decoder.outputItems.map(\.wire)
            guard try JSONEncoder().encode(history).count <= 1_048_576 else { throw AIProviderError.outputLimit }
            pending = Set(decoder.outputItems.compactMap(\.call).map(\.id))
            continuation.yield(.completed); continuation.finish()
        } catch {
            closed = true; history = []; request = nil
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { outcome = .cancelled }
            continuation.finish(throwing: error)
        }
    }
    func close() async {
        closed = true; let task = worker; task?.cancel(); await task?.value
        history = []; request = nil; pending = []
    }
}
