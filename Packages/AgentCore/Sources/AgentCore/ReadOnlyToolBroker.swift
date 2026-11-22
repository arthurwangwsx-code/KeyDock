import Foundation
import AICore
import ExecutionCore

/// 首版只注册宿主提供的只读工具；该协议不是第三方进程沙箱。
public protocol ReadOnlyAITool: Sendable {
    var definition: AIToolDefinition { get }
    func call(arguments: [String: JSONValue]) async throws -> String
}

public actor ToolBroker {
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

/// 有意限制的 schema 子集；不静默忽略尚未实现的关键字。
public enum ToolJSONSchema {
    private static let supported: Set<String> = [
        "type", "properties", "required", "additionalProperties", "description", "enum", "items",
        "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"
    ]
    public static func checkSchema(_ schema: [String: JSONValue], depth: Int = 0) throws {
        guard depth <= 8, Set(schema.keys).isSubset(of: supported),
              let type = schema["type"]?.stringValue,
              ["object", "array", "string", "number", "integer", "boolean", "null"].contains(type) else {
            throw AIProviderError.invalidToolSchema
        }
        if depth == 0 && type != "object" { throw AIProviderError.invalidToolSchema }
        if type == "object" {
            guard let properties = schema["properties"]?.objectValue,
                  schema["additionalProperties"] == .bool(false), properties.count <= 64 else {
                throw AIProviderError.invalidToolSchema
            }
            for property in properties.values {
                guard let nested = property.objectValue else { throw AIProviderError.invalidToolSchema }
                try checkSchema(nested, depth: depth + 1)
            }
            if let required = schema["required"] {
                guard let list = required.arrayValue,
                      list.allSatisfy({ $0.stringValue.map { properties[$0] != nil } == true }),
                      Set(list.compactMap(\.stringValue)).count == list.count else {
                    throw AIProviderError.invalidToolSchema
                }
            }
        }
        if type == "array" {
            guard let items = schema["items"]?.objectValue else { throw AIProviderError.invalidToolSchema }
            try checkSchema(items, depth: depth + 1)
        }
        for field in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] where schema[field] != nil {
            guard let number = schema[field]?.numberValue, number.isFinite else { throw AIProviderError.invalidToolSchema }
            if field.hasSuffix("Length") || field.hasSuffix("Items") {
                guard number >= 0, number.rounded(.down) == number else { throw AIProviderError.invalidToolSchema }
            }
        }
        if let values = schema["enum"]?.arrayValue, values.isEmpty { throw AIProviderError.invalidToolSchema }
        if schema["enum"] != nil && schema["enum"]?.arrayValue == nil { throw AIProviderError.invalidToolSchema }
    }

    public static func validate(_ value: JSONValue, schema: [String: JSONValue], depth: Int = 0) throws {
        guard depth <= 8, let type = schema["type"]?.stringValue else { throw AIProviderError.invalidToolSchema }
        if let values = schema["enum"]?.arrayValue, !values.contains(value) { throw AIProviderError.invalidToolArguments }
        switch (type, value) {
        case ("object", .object(let object)):
            guard let properties = schema["properties"]?.objectValue,
                  Set(object.keys).isSubset(of: Set(properties.keys)) else { throw AIProviderError.invalidToolArguments }
            for required in schema["required"]?.arrayValue ?? [] {
                guard let key = required.stringValue, object[key] != nil else { throw AIProviderError.invalidToolArguments }
            }
            for (key, child) in object {
                guard let nested = properties[key]?.objectValue else { throw AIProviderError.invalidToolSchema }
                try validate(child, schema: nested, depth: depth + 1)
            }
        case ("array", .array(let array)):
            try bounds(Double(array.count), minimum: schema["minItems"], maximum: schema["maxItems"])
            guard let items = schema["items"]?.objectValue else { throw AIProviderError.invalidToolSchema }
            for child in array { try validate(child, schema: items, depth: depth + 1) }
        case ("string", .string(let string)):
            try bounds(Double(string.count), minimum: schema["minLength"], maximum: schema["maxLength"])
        case ("number", .number(let number)):
            guard number.isFinite else { throw AIProviderError.invalidToolArguments }
            try bounds(number, minimum: schema["minimum"], maximum: schema["maximum"])
        case ("integer", .number(let number)):
            guard number.isFinite, number.rounded(.towardZero) == number else { throw AIProviderError.invalidToolArguments }
            try bounds(number, minimum: schema["minimum"], maximum: schema["maximum"])
        case ("boolean", .bool), ("null", .null): break
        default: throw AIProviderError.invalidToolArguments
        }
    }
    private static func bounds(_ value: Double, minimum: JSONValue?, maximum: JSONValue?) throws {
        if let number = minimum?.numberValue, value < number { throw AIProviderError.invalidToolArguments }
        if let number = maximum?.numberValue, value > number { throw AIProviderError.invalidToolArguments }
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
