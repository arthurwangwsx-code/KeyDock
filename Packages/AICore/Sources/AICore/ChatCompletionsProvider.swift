import Foundation

public struct AIHTTPResponse: Sendable {
    public var statusCode: Int
    public var contentType: String?
    public var body: AsyncThrowingStream<Data, any Error>
    public var cancel: @Sendable () -> Void
    public init(statusCode: Int, contentType: String? = "text/event-stream",
                body: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void = {}) {
        self.statusCode = statusCode; self.contentType = contentType; self.body = body; self.cancel = cancel
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
            let body = AsyncThrowingStream<Data, any Error> { continuation in
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
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    session.invalidateAndCancel()
                }
            }
            return AIHTTPResponse(statusCode: response.statusCode,
                                  contentType: response.value(forHTTPHeaderField: "Content-Type"), body: body,
                                  cancel: { session.invalidateAndCancel() })
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }
}

public struct ChatCompletionsProvider: AIProvider {
    public let configuration: AIProviderConfiguration
    private let apiKey: String
    private let transport: any AIHTTPTransport

    public init(configuration: AIProviderConfiguration, apiKey: String,
                transport: any AIHTTPTransport = URLSessionAITransport()) {
        self.configuration = configuration; self.apiKey = apiKey; self.transport = transport
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let wire = try makeURLRequest(request)
                    try Task.checkCancellation()
                    let response = try await transport.open(wire)
                    defer { response.cancel() }
                    guard (200..<300).contains(response.statusCode) else {
                        throw AIProviderError.httpStatus(response.statusCode)
                    }
                    guard response.contentType?.lowercased().hasPrefix("text/event-stream") == true else {
                        throw AIProviderError.invalidContentType
                    }
                    var parser = SSEEventParser()
                    var decoder = ChatStreamDecoder(allowedTools: Set(request.tools.map(\.name)))
                    streamLoop: for try await data in response.body {
                        try Task.checkCancellation()
                        for byte in data {
                            if let payload = try parser.feed(byte) {
                                for event in try decoder.consume(payload) {
                                    if case .completed = event { continue }
                                    continuation.yield(event)
                                }
                                if decoder.isComplete { break streamLoop }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    try decoder.finish()
                    continuation.yield(.completed)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func makeURLRequest(_ request: AIRequest) throws -> URLRequest {
        try configuration.validate()
        guard !request.messages.isEmpty, request.messages.count <= 128,
              (1...32_768).contains(request.maxTokens), request.tools.count <= 16,
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
            configuration.tokenLimitParameter.rawValue: .number(Double(request.maxTokens)),
            "store": .bool(false)
        ]
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
