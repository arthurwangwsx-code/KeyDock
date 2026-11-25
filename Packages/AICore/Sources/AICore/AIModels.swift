import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
}

public enum TokenLimitParameter: String, Codable, CaseIterable, Sendable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable {
    public var endpoint: URL
    public var model: String
    public var allowsLocalHTTP: Bool
    public var tokenLimitParameter: TokenLimitParameter
    public var timeout: TimeInterval

    public init(endpoint: URL, model: String, allowsLocalHTTP: Bool = false,
                tokenLimitParameter: TokenLimitParameter = .maxCompletionTokens, timeout: TimeInterval = 120) {
        self.endpoint = endpoint
        self.model = model
        self.allowsLocalHTTP = allowsLocalHTTP
        self.tokenLimitParameter = tokenLimitParameter
        self.timeout = timeout
    }

    public func validate() throws {
        let scheme = endpoint.scheme?.lowercased()
        let host = endpoint.host?.lowercased() ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && allowsLocalHTTP && loopback),
              !host.isEmpty, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 256, timeout > 0, timeout <= 600 else {
            throw AIProviderError.invalidConfiguration
        }
    }
}

public struct AIToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct AIMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    public var toolCalls: [AIToolCall]?
    public var toolCallID: String?
    public init(role: String, content: String, toolCalls: [AIToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }
}

public struct AIToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// 完整 object schema，首版 Broker 仅支持显式列出的严格子集。
    public var parameters: [String: JSONValue]
    public init(name: String, description: String, parameters: [String: JSONValue]) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public struct AIRequest: Sendable {
    public var messages: [AIMessage]
    public var maxTokens: Int
    public var tools: [AIToolDefinition]
    public init(messages: [AIMessage], maxTokens: Int = 2048, tools: [AIToolDefinition] = []) {
        self.messages = messages; self.maxTokens = maxTokens; self.tools = tools
    }
}

public struct AIUsage: Codable, Equatable, Sendable {
    public enum Counting: String, Codable, Sendable { case cumulative, delta }
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var attemptID: UUID
    public var responseID: String?
    public var counting: Counting
    public init(inputTokens: Int?, outputTokens: Int?, attemptID: UUID,
                responseID: String? = nil, counting: Counting = .cumulative) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.attemptID = attemptID; self.responseID = responseID; self.counting = counting
    }
}

public enum AIEvent: Sendable {
    case text(String)
    case toolCall(AIToolCall)
    case usage(AIUsage)
    case completed
}

public protocol AIProvider: Sendable {
    var usageRecorder: AIUsageRecorder? { get }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error>
}
public extension AIProvider { var usageRecorder: AIUsageRecorder? { nil } }

/// 错误只含稳定类别；不能把服务端正文、prompt 或凭据拼入普通日志。
public enum AIProviderError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case httpStatus(Int)
    case invalidContentType
    case malformedEvent
    case unexpectedToolCall
    case unknownTool
    case invalidToolArguments
    case invalidToolSchema
    case truncatedStream
    case outputLimit
    case tokenLimit
    case contentFiltered
    case toolBudgetExceeded
    case deadlineExceeded
    case modelServiceError
}

public struct MockAIProvider: AIProvider {
    public var text: String
    public var delay: Duration
    public init(text: String = "Synthetic AI result", delay: Duration = .milliseconds(1)) {
        self.text = text; self.delay = delay
    }
    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for character in text {
                        try Task.checkCancellation()
                        try await Task.sleep(for: delay)
                        continuation.yield(.text(String(character)))
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
