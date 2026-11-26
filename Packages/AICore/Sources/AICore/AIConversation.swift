import Foundation

public struct AIToolOutput: Sendable {
    public let callID: String
    public let output: String
    public init(callID: String, output: String) { self.callID = callID; self.output = output }
}
public enum AIConversationInput: Sendable { case initial(AIRequest), toolOutputs([AIToolOutput], maxOutputTokens: Int? = nil) }
public protocol AIConversation: Sendable {
    func stream(_ input: AIConversationInput) async -> AsyncThrowingStream<AIEvent, any Error>
    func close() async
}

/// 每run独享Chat历史；测试provider也经同一会话合同，不向业务层暴露Responses密文。
actor ChatAIConversation: AIConversation {
    let provider: any AIProvider
    var request: AIRequest?
    var pending: Set<String> = []
    var closed = false
    var worker: Task<Void, Never>?
    init(provider: any AIProvider) { self.provider = provider }
    func stream(_ input: AIConversationInput) async -> AsyncThrowingStream<AIEvent, any Error> {
        guard !closed, worker == nil else { return .init { $0.finish(throwing: AIProviderError.invalidRequest) } }
        do {
            switch input {
            case .initial(let value): guard request == nil else { throw AIProviderError.invalidRequest }; request = value
            case .toolOutputs(let values, let cap):
                guard request != nil, !pending.isEmpty, values.count == pending.count,
                      Set(values.map(\.callID)) == pending else { throw AIProviderError.invalidRequest }
                guard cap.map({ (1...32_768).contains($0) }) ?? true else { throw AIProviderError.invalidRequest }
                guard values.allSatisfy({ $0.output.utf8.count <= 1_048_576 }) else { throw AIProviderError.outputLimit }
                request!.messages += values.map { .init(role: "tool", content: $0.output, toolCallID: $0.callID) }
                if let cap { request!.maxTokens = cap }
                pending = []
            }
            let value = request!
            let (stream, continuation) = AsyncThrowingStream<AIEvent, any Error>.makeStream()
            let task = Task { await consume(value, continuation: continuation) }
            worker = task
            continuation.onTermination = { @Sendable reason in if case .cancelled = reason { task.cancel() } }
            return stream
        } catch { return .init { $0.finish(throwing: error) } }
    }
    private func consume(_ value: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async {
        defer { worker = nil }
        do {
            var text = "", calls: [AIToolCall] = [], complete = false
            for try await event in provider.stream(value) {
                try Task.checkCancellation()
                guard !closed, !complete else { throw AIProviderError.malformedEvent }
                switch event {
                case .text(let delta): text += delta
                case .toolCall(let call): calls.append(call)
                case .completed: complete = true
                case .usage: break
                }
                if case .completed = event { continue }
                continuation.yield(event)
            }
            try Task.checkCancellation()
            guard !closed, complete, Set(calls.map(\.id)).count == calls.count else { throw AIProviderError.truncatedStream }
            if !calls.isEmpty {
                request!.messages.append(.init(role: "assistant", content: text, toolCalls: calls))
                pending = Set(calls.map(\.id))
            }
            continuation.yield(.completed); continuation.finish()
        } catch { closed = true; continuation.finish(throwing: error) }
    }
    func close() async {
        closed = true; let task = worker; task?.cancel(); await task?.value
        request = nil; pending = []
    }
}

/// 不共享会话；只共享本次run的冻结配置、transport和独享用量记录器。
public struct ResolvedAIProvider: AIProvider {
    public let configuration: AIProviderConfiguration
    public let usageRecorder: AIUsageRecorder?
    private let apiKey: String
    private let transport: any AIHTTPTransport
    public init(configuration: AIProviderConfiguration, apiKey: String,
                transport: any AIHTTPTransport = URLSessionAITransport(), usageRecorder: AIUsageRecorder? = nil) {
        self.configuration = configuration; self.apiKey = apiKey; self.transport = transport; self.usageRecorder = usageRecorder
    }
    public func withFreshUsageRecorder() -> Self {
        .init(configuration: configuration, apiKey: apiKey, transport: transport, usageRecorder: AIUsageRecorder(rate: usageRecorder?.frozenRate))
    }
    public func makeConversation() -> any AIConversation {
        if configuration.requestProtocol == .responses {
            return ResponsesAIConversation(configuration: configuration, apiKey: apiKey, transport: transport, recorder: usageRecorder)
        }
        return ChatCompletionsProvider(configuration: configuration, apiKey: apiKey, transport: transport, usageRecorder: usageRecorder).makeConversation()
    }
    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        if configuration.requestProtocol == .chatCompletions {
            return ChatCompletionsProvider(configuration: configuration, apiKey: apiKey, transport: transport, usageRecorder: usageRecorder).stream(request)
        }
        return AsyncThrowingStream { continuation in
            let conversation = makeConversation()
            let task = Task {
                do {
                    var complete = false
                    for try await event in await conversation.stream(.initial(request)) {
                        try Task.checkCancellation()
                        if case .completed = event { complete = true } else { continuation.yield(event) }
                    }
                    await conversation.close()
                    try Task.checkCancellation()
                    guard complete else { throw AIProviderError.truncatedStream }
                    continuation.yield(.completed); continuation.finish()
                } catch { await conversation.close(); continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable reason in if case .cancelled = reason { task.cancel() } }
        }
    }
}
