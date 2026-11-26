import Foundation

/// 按字节积累到完整 UTF-8 行，不在任意网络分片处解码中文。
public struct SSEEventParser: Sendable {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var firstLine = true
    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    public init(maximumLineBytes: Int = 262_144, maximumEventBytes: Int = 524_288) {
        self.maximumLineBytes = max(1, min(2_097_152, maximumLineBytes))
        self.maximumEventBytes = max(1, min(2_097_152, maximumEventBytes))
    }

    public mutating func feed(_ byte: UInt8) throws -> String? {
        if byte != 10 {
            line.append(byte)
            guard line.count <= maximumLineBytes else { throw AIProviderError.outputLimit }
            return nil
        }
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if bytes.last == 13 { bytes.removeLast() }
        if firstLine {
            firstLine = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard let decoded = String(data: bytes, encoding: .utf8) else { throw AIProviderError.malformedEvent }
        if decoded.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let event = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            return event
        }
        if decoded.hasPrefix(":") { return nil }
        let pieces = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces[0] == "data" else { return nil }
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.first == " " { value.removeFirst() }
        eventBytes += value.utf8.count
        guard eventBytes <= maximumEventBytes else { throw AIProviderError.outputLimit }
        dataLines.append(value)
        return nil
    }
}

private struct CompletionChunk: Decodable {
    struct Usage: Decodable { var prompt_tokens: Int?; var completion_tokens: Int? }
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolDelta: Decodable {
                struct Function: Decodable { var name: String?; var arguments: String? }
                var index: Int
                var id: String?
                var type: String?
                var function: Function?
            }
            var content: String?
            var refusal: String?
            var tool_calls: [ToolDelta]?
            var function_call: JSONValue?
        }
        var index: Int
        var delta: Delta?
        var finish_reason: String?
    }
    var id: String?
    var choices: [Choice]?
    var usage: Usage?
    var error: JSONValue?
}

/// 一个实例对应一次真实请求；累计用量按快照合并，工具参数只在完整结束后交付。
public struct ChatStreamDecoder: Sendable {
    private struct PartialTool: Sendable { var id = ""; var name = ""; var arguments = "" }
    private var tools: [Int: PartialTool] = [:]
    private var allowedTools: Set<String>
    private var responseID: String?
    private var finishReason: String?
    private var lastUsage: AIUsage?
    /// 同一payload后续内容失败也不能抹去已验证的token事实。
    public var latestValidatedUsage: AIUsage? { lastUsage }
    private var outputBytes = 0
    public let attemptID: UUID
    public private(set) var isComplete = false

    public init(allowedTools: Set<String> = [], attemptID: UUID = UUID()) {
        self.allowedTools = allowedTools; self.attemptID = attemptID
    }

    public mutating func consume(_ payload: String) throws -> [AIEvent] {
        guard !isComplete else { throw AIProviderError.malformedEvent }
        if payload == "[DONE]" {
            guard let reason = finishReason else { throw AIProviderError.truncatedStream }
            var events: [AIEvent] = []
            if reason == "tool_calls" {
                guard !tools.isEmpty else { throw AIProviderError.malformedEvent }
                for index in tools.keys.sorted() {
                    guard let item = tools[index], !item.id.isEmpty, allowedTools.contains(item.name),
                          let bytes = item.arguments.data(using: .utf8),
                          (try? JSONDecoder().decode([String: JSONValue].self, from: bytes)) != nil else {
                        throw AIProviderError.invalidToolArguments
                    }
                    events.append(.toolCall(.init(id: item.id, name: item.name, arguments: item.arguments)))
                }
            } else if !tools.isEmpty { throw AIProviderError.malformedEvent }
            isComplete = true
            events.append(.completed)
            return events
        }
        let chunk: CompletionChunk
        do { chunk = try JSONDecoder().decode(CompletionChunk.self, from: Data(payload.utf8)) }
        catch { throw AIProviderError.malformedEvent }
        if chunk.error != nil { throw AIProviderError.modelServiceError }
        guard let choices = chunk.choices, choices.count <= 1 else { throw AIProviderError.malformedEvent }
        if let id = chunk.id {
            guard responseID == nil || responseID == id else { throw AIProviderError.malformedEvent }
            responseID = id
        }
        var events: [AIEvent] = []
        if let usage = chunk.usage {
            guard (usage.prompt_tokens ?? 0) >= 0, (usage.completion_tokens ?? 0) >= 0 else {
                throw AIProviderError.malformedEvent
            }
            let value = AIUsage(inputTokens: usage.prompt_tokens, outputTokens: usage.completion_tokens,
                                attemptID: attemptID, responseID: responseID)
            if value != lastUsage { events.append(.usage(value)); lastUsage = value }
        }
        for choice in choices {
            guard choice.index == 0 else { throw AIProviderError.malformedEvent }
            let delta = choice.delta
            if let value = delta?.content, !value.isEmpty {
                guard finishReason == nil else { throw AIProviderError.malformedEvent }
                outputBytes += value.utf8.count
                guard outputBytes <= 1_048_576 else { throw AIProviderError.outputLimit }
                events.append(.text(value))
            }
            if let refusal = delta?.refusal, !refusal.isEmpty {
                throw AIProviderError.contentFiltered
            }
            if delta?.function_call != nil { throw AIProviderError.unexpectedToolCall }
            for fragment in delta?.tool_calls ?? [] {
                guard !allowedTools.isEmpty else { throw AIProviderError.unexpectedToolCall }
                guard finishReason == nil, fragment.index >= 0, fragment.index < 16,
                      fragment.type == nil || fragment.type == "function" else { throw AIProviderError.malformedEvent }
                var tool = tools[fragment.index] ?? PartialTool()
                if let id = fragment.id {
                    guard tool.id.isEmpty || tool.id == id else { throw AIProviderError.malformedEvent }
                    tool.id = id
                }
                if let name = fragment.function?.name { tool.name += name }
                if let arguments = fragment.function?.arguments { tool.arguments += arguments }
                guard tool.id.utf8.count <= 256, tool.name.utf8.count <= 128,
                      tool.arguments.utf8.count <= 65_536 else { throw AIProviderError.outputLimit }
                tools[fragment.index] = tool
            }
            if let reason = choice.finish_reason {
                guard finishReason == nil else { throw AIProviderError.malformedEvent }
                switch reason {
                case "stop", "tool_calls": finishReason = reason
                case "length": throw AIProviderError.tokenLimit
                case "content_filter": throw AIProviderError.contentFiltered
                default: throw AIProviderError.malformedEvent
                }
            }
        }
        return events
    }

    public func finish() throws {
        guard isComplete else { throw AIProviderError.truncatedStream }
    }
}
