import Foundation

public struct AIHTTPResponse: Sendable {
    public var statusCode: Int
    public var contentType: String?
    public var body: AsyncThrowingStream<Data, any Error>
    public var cancel: @Sendable () -> Void
    public var waitForCompletion: @Sendable () async -> Void
    public init(statusCode: Int, contentType: String? = "text/event-stream",
                body: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void = {},
                waitForCompletion: @escaping @Sendable () async -> Void = {}) {
        self.statusCode = statusCode; self.contentType = contentType; self.body = body; self.cancel = cancel; self.waitForCompletion = waitForCompletion
    }
}

public protocol AIHTTPTransport: Sendable {
    func open(_ request: URLRequest) async throws -> AIHTTPResponse
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 首版拒绝全部重定向，凭据不会随跳转流向其他来源。
        completionHandler(nil)
    }
}

public struct URLSessionAITransport: AIHTTPTransport {
    public init() {}
    public func open(_ request: URLRequest) async throws -> AIHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                session.invalidateAndCancel()
                throw AIProviderError.malformedEvent
            }
            let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let task = Task {
                    defer { session.invalidateAndCancel() }
                    do {
                        var buffer = Data()
                        var total = 0
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            total += 1
                            guard total <= 33_554_432 else { throw AIProviderError.outputLimit }
                            buffer.append(byte)
                            // 每个事件的空行处交付，避免等待较大缓冲影响首 token。
                            if byte == 10 || buffer.count >= 4096 {
                                switch continuation.yield(buffer) {
                                case .enqueued: break
                                case .dropped: throw AIProviderError.outputLimit
                                case .terminated: throw CancellationError()
                                @unknown default: throw AIProviderError.outputLimit
                                }
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { task.cancel(); session.invalidateAndCancel() }
            }
            return AIHTTPResponse(statusCode: response.statusCode,
                                  contentType: response.value(forHTTPHeaderField: "Content-Type"), body: body,
                                  cancel: { task.cancel(); session.invalidateAndCancel() }, waitForCompletion: { await task.value })
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }
}

public struct ChatCompletionsProvider: AIProvider {
    public let configuration: AIProviderConfiguration
    public let usageRecorder: AIUsageRecorder?
    private let apiKey: String
    private let transport: any AIHTTPTransport

    public init(configuration: AIProviderConfiguration, apiKey: String,
                transport: any AIHTTPTransport = URLSessionAITransport(), usageRecorder: AIUsageRecorder? = nil) {
        self.configuration = configuration; self.apiKey = apiKey; self.transport = transport
        self.usageRecorder = usageRecorder
    }

    /// 工作流每个实际AI步骤独享记录器，仍使用该run准备时冻结的费率与服务。
    public func withFreshUsageRecorder() -> Self {
        .init(configuration: configuration, apiKey: apiKey, transport: transport, usageRecorder: AIUsageRecorder(rate: usageRecorder?.frozenRate))
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        let worker = usageRecorder?.beginWorker()
        if usageRecorder != nil && worker == nil { return AsyncThrowingStream { $0.finish(throwing: CancellationError()) } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var attempt: UUID?, outcome = AIRecordedCall.Outcome.failed
                defer {
                    if let attempt { usageRecorder?.finishAttempt(attempt, outcome: outcome) }
                    if let worker { usageRecorder?.endWorker(worker) }
                }
                do {
                    let wire = try makeURLRequest(request)
                    try Task.checkCancellation()
                    if let usageRecorder {
                        guard let worker, let started = usageRecorder.beginAttempt(worker: worker, configuration: configuration) else { throw CancellationError() }
                        attempt = started
                    } else { attempt = UUID() }
                    let response = try await transport.open(wire)
                    do {
                        try await withTaskCancellationHandler {
                            try await consume(response, request: request, attempt: attempt!, continuation: continuation)
                        } onCancel: { response.cancel() }
                    } catch {
                        response.cancel(); await response.waitForCompletion(); throw error
                    }
                    response.cancel(); await response.waitForCompletion()
                    outcome = .succeeded
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { outcome = .cancelled }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in if case .cancelled = reason { task.cancel() } }
        }
    }

    private func consume(_ response: AIHTTPResponse, request: AIRequest, attempt: UUID,
                         continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        guard (200..<300).contains(response.statusCode) else {
            throw AIProviderError.httpStatus(response.statusCode)
        }
        guard response.contentType?.lowercased().hasPrefix("text/event-stream") == true else {
            throw AIProviderError.invalidContentType
        }
        var parser = SSEEventParser()
        var decoder = ChatStreamDecoder(allowedTools: Set(request.tools.map(\.name)), attemptID: attempt)
        streamLoop: for try await data in response.body {
            try Task.checkCancellation()
            for byte in data {
                if let payload = try parser.feed(byte) {
                    let events: [AIEvent]
                    do { events = try decoder.consume(payload) }
                    catch {
                        if let usage = decoder.latestValidatedUsage { usageRecorder?.observe(usage) }
                        throw error
                    }
                    for event in events {
                        if case .completed = event { continue }
                        if case .usage(let value) = event { usageRecorder?.observe(value) }
                        continuation.yield(event)
                    }
                    if decoder.isComplete { break streamLoop }
                }
            }
        }
        try Task.checkCancellation()
        try decoder.finish()
    }

    public func makeURLRequest(_ request: AIRequest) throws -> URLRequest {
        try configuration.validate()
        try AIModelCatalog.validate(configuration, requiresTools: !request.tools.isEmpty)
        let budget = request.maxTokens ?? configuration.maxOutputTokens
        guard configuration.requestProtocol == .chatCompletions,
              !request.messages.isEmpty, request.messages.count <= 128,
              (1...32_768).contains(budget), budget <= configuration.maxOutputTokens, request.tools.count <= 16,
              !apiKey.contains("\n"), !apiKey.contains("\r") else { throw AIProviderError.invalidRequest }
        var messages: [JSONValue] = []
        for message in request.messages {
            guard ["system", "developer", "user", "assistant", "tool"].contains(message.role),
                  message.content.utf8.count <= 1_048_576 else { throw AIProviderError.invalidRequest }
            var wire: [String: JSONValue] = ["role": .string(message.role), "content": .string(message.content)]
            if let calls = message.toolCalls, !calls.isEmpty {
                guard message.role == "assistant", calls.count <= 16 else { throw AIProviderError.invalidRequest }
                wire["tool_calls"] = .array(calls.map { call in
                    .object(["id": .string(call.id), "type": .string("function"),
                             "function": .object(["name": .string(call.name), "arguments": .string(call.arguments)])])
                })
                if message.content.isEmpty { wire["content"] = .null }
            }
            if message.role == "tool" {
                guard let id = message.toolCallID, !id.isEmpty else { throw AIProviderError.invalidRequest }
                wire["tool_call_id"] = .string(id)
            } else if message.toolCallID != nil { throw AIProviderError.invalidRequest }
            messages.append(.object(wire))
        }
        let names = Set(request.tools.map(\.name))
        guard names.count == request.tools.count else { throw AIProviderError.invalidRequest }
        var body: [String: JSONValue] = [
            "model": .string(configuration.model), "messages": .array(messages), "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
            configuration.tokenLimitParameter.rawValue: .number(Double(budget)),
            "store": .bool(false)
        ]
        if let effort = configuration.reasoningEffort { body["reasoning_effort"] = .string(effort) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object(["type": .string("function"),
                         "function": .object(["name": .string(tool.name), "description": .string(tool.description),
                                              "parameters": .object(tool.parameters)])])
            })
            body["tool_choice"] = .string("auto")
        }
        let encoded = try JSONEncoder().encode(body)
        guard encoded.count <= 2_097_152 else { throw AIProviderError.invalidRequest }
        var wire = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.timeout)
        wire.httpMethod = "POST"
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { wire.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        wire.httpBody = encoded
        return wire
    }
}
