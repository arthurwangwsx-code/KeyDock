import Foundation
import AICore
import ExecutionCore

/// 首版只注册宿主提供的只读工具；该协议不是第三方进程沙箱。
public protocol ReadOnlyAITool: Sendable {
    var definition: AIToolDefinition { get }
    func call(arguments: [String: JSONValue]) async throws -> String
}

public protocol AgentToolRouting: Sendable {
    func definitions() async -> [AIToolDefinition]
    func invoke(_ call: AIToolCall, allowed: Set<String>) async throws -> String
}
public actor ToolBroker: AgentToolRouting {
    private let tools: [String: any ReadOnlyAITool]
    private let callerInstanceID = UUID().uuidString
    private let frozenDefinitions: [String: AIToolDefinition]
    public init(tools: [any ReadOnlyAITool]) throws {
        var map: [String: any ReadOnlyAITool] = [:]
        var definitions: [String: AIToolDefinition] = [:]
        for tool in tools {
            let definition = tool.definition
            guard definition.name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  map[definition.name] == nil else { throw AIProviderError.invalidToolSchema }
            try ToolJSONSchema.checkSchema(definition.parameters)
            map[definition.name] = tool; definitions[definition.name] = definition
        }
        self.tools = map; self.frozenDefinitions = definitions
    }
    public func definitions() -> [AIToolDefinition] {
        frozenDefinitions.keys.sorted().compactMap { frozenDefinitions[$0] }
    }
    public func invoke(_ call: AIToolCall, allowed: Set<String>) async throws -> String {
        try Task.checkCancellation()
        guard allowed.contains(call.name), let tool = tools[call.name], let definition = frozenDefinitions[call.name] else { throw AIProviderError.unknownTool }
        guard call.arguments.utf8.count <= 65_536,
              let data = call.arguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw AIProviderError.invalidToolArguments
        }
        try ToolJSONSchema.validate(.object(arguments), schema: definition.parameters)
        let toolID = "keydock.ai." + definition.name
        let request = ExecutionRequest(commandID: "keydock.agent.read-only", commandVersion: 1, toolID: toolID, toolVersion: 1, caller: .agent, callerInstanceID: callerInstanceID, resourceScope: .none, effects: [.read])
        let grant = PolicyGrant(caller: .agent, callerInstanceID: callerInstanceID, commandID: request.commandID, commandVersion: 1, toolID: toolID, toolVersion: 1, resourceScope: .none, allowedEffects: [.read], expiresAt: Date().addingTimeInterval(60), invocationID: request.invocationID)
        try ExecutionPolicy.authorize(request: request, grant: grant)
        try Task.checkCancellation()
        let result = try await tool.call(arguments: arguments)
        try Task.checkCancellation()
        guard result.utf8.count <= 65_536 else { throw AIProviderError.outputLimit }
        return result
    }
}

public struct CurrentTimeTool: ReadOnlyAITool {
    public init() {}
    public var definition: AIToolDefinition {
        .init(name: "current_time", description: "Read the current ISO-8601 time. This tool has no write effects.",
              parameters: ["type": .string("object"), "properties": .object([:]),
                           "additionalProperties": .bool(false), "required": .array([])])
    }
    public func call(arguments: [String: JSONValue]) async throws -> String {
        try Task.checkCancellation()
        return ISO8601DateFormatter().string(from: Date())
    }
}
