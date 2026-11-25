import Foundation
import AICore

/// 明确的有界schema子集；annotation保留为数据，未知约束拒绝，不改写服务端声明。
public enum ToolJSONSchema {
    private static let supported: Set<String> = [
        "type","properties","required","additionalProperties","enum","items","minimum","maximum","minLength","maxLength","minItems","maxItems",
        "title","description","default","examples","deprecated","readOnly","writeOnly"
    ]
    public static func checkSchema(_ schema:[String:JSONValue],depth:Int = 0) throws {
        try budget(.object(schema),error:.invalidToolSchema)
        try checkNode(schema,depth:depth)
        if depth == 0 && schema["type"] != .string("object") { throw AIProviderError.invalidToolSchema }
    }
    private static func checkNode(_ schema:[String:JSONValue],depth:Int) throws {
        guard (0...8).contains(depth), Set(schema.keys).isSubset(of:supported),
              let type = schema["type"]?.stringValue,
              ["object","array","string","number","integer","boolean","null"].contains(type) else { throw AIProviderError.invalidToolSchema }
        for name in ["title","description"] where schema[name] != nil {
            guard schema[name]?.stringValue != nil else { throw AIProviderError.invalidToolSchema }
        }
        for name in ["deprecated","readOnly","writeOnly"] where schema[name] != nil {
            guard case .bool = schema[name] else { throw AIProviderError.invalidToolSchema }
        }
        if let examples = schema["examples"], examples.arrayValue == nil { throw AIProviderError.invalidToolSchema }
        if let properties = schema["properties"] {
            guard let fields = properties.objectValue, fields.count <= 64 else { throw AIProviderError.invalidToolSchema }
            for child in fields.values {
                guard let nested = child.objectValue else { throw AIProviderError.invalidToolSchema }
                try checkNode(nested,depth:depth+1)
            }
        }
        if let additional = schema["additionalProperties"] {
            switch additional {
            case .bool: break
            case .object(let nested): try checkNode(nested,depth:depth+1)
            default: throw AIProviderError.invalidToolSchema
            }
        }
        if let required = schema["required"] {
            guard let list = required.arrayValue, list.allSatisfy({$0.stringValue != nil}),
                  Set(list.compactMap(\.stringValue).map { Data($0.utf8) }).count == list.count else { throw AIProviderError.invalidToolSchema }
        }
        if let items = schema["items"] {
            guard let nested = items.objectValue else { throw AIProviderError.invalidToolSchema }
            try checkNode(nested,depth:depth+1)
        } else if type == "array" { throw AIProviderError.invalidToolSchema }
        for name in ["minimum","maximum","minLength","maxLength","minItems","maxItems"] where schema[name] != nil {
            guard let value = schema[name]?.numberValue, value.isFinite else { throw AIProviderError.invalidToolSchema }
            if name.hasSuffix("Length") || name.hasSuffix("Items") {
                guard value >= 0, value.rounded(.down) == value else { throw AIProviderError.invalidToolSchema }
            }
        }
        if let values = schema["enum"] { guard let values = values.arrayValue, !values.isEmpty else { throw AIProviderError.invalidToolSchema } }
        // default只是annotation，既不注入参数，也不要求匹配本节点的断言。
    }
    public static func validate(_ value:JSONValue,schema:[String:JSONValue],depth:Int = 0) throws {
        try budget(.object(schema),error:.invalidToolSchema)
        try checkNode(schema,depth:depth)
        try budget(value,error:.invalidToolArguments)
        try validateNode(value,schema:schema,depth:depth)
    }
    private static func validateNode(_ value:JSONValue,schema:[String:JSONValue],depth:Int) throws {
        guard depth <= 8, let type = schema["type"]?.stringValue else { throw AIProviderError.invalidToolSchema }
        if let values = schema["enum"]?.arrayValue, !values.contains(where:{equalJSON($0,value)}) { throw AIProviderError.invalidToolArguments }
        switch (type,value) {
        case ("object",.object(let object)):
            let fields = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue ?? [] {
                guard let key = required.stringValue, object.keys.contains(where:{$0.utf8.elementsEqual(key.utf8)}) else { throw AIProviderError.invalidToolArguments }
            }
            for (key,child) in object {
                if let declared = fields.first(where:{$0.key.utf8.elementsEqual(key.utf8)}), let nested = declared.value.objectValue {
                    try validateNode(child,schema:nested,depth:depth+1)
                } else {
                    switch schema["additionalProperties"] {
                    case .bool(false): throw AIProviderError.invalidToolArguments
                    case .object(let nested): try validateNode(child,schema:nested,depth:depth+1)
                    default: break // 省略或true均为开放对象；额外值已受全局JSON预算约束。
                    }
                }
            }
        case ("array",.array(let array)):
            try bounds(Double(array.count),minimum:schema["minItems"],maximum:schema["maxItems"])
            guard let nested = schema["items"]?.objectValue else { throw AIProviderError.invalidToolSchema }
            for child in array { try validateNode(child,schema:nested,depth:depth+1) }
        case ("string",.string(let string)):
            try bounds(Double(string.unicodeScalars.count),minimum:schema["minLength"],maximum:schema["maxLength"])
        case ("number",.number(let number)):
            guard number.isFinite else { throw AIProviderError.invalidToolArguments }
            try bounds(number,minimum:schema["minimum"],maximum:schema["maximum"])
        case ("integer",.number(let number)):
            guard number.isFinite, number.rounded(.towardZero) == number else { throw AIProviderError.invalidToolArguments }
            try bounds(number,minimum:schema["minimum"],maximum:schema["maximum"])
        case ("boolean",.bool),("null",.null): break
        default: throw AIProviderError.invalidToolArguments
        }
    }
    private static func bounds(_ value:Double,minimum:JSONValue?,maximum:JSONValue?) throws {
        if let min = minimum?.numberValue, value < min { throw AIProviderError.invalidToolArguments }
        if let max = maximum?.numberValue, value > max { throw AIProviderError.invalidToolArguments }
    }
    private static func budget(_ value:JSONValue,error:AIProviderError) throws {
        var nodes = 0
        func visit(_ node:JSONValue,_ depth:Int) throws {
            nodes += 1; guard nodes <= 8192, depth <= 32 else { throw error }
            switch node {
            case .number(let value): guard value.isFinite else { throw error }
            case .array(let values): for child in values { try visit(child,depth+1) }
            case .object(let values): for child in values.values { try visit(child,depth+1) }
            default: break
            }
        }
        try visit(value,0)
        guard let encoded = try? JSONEncoder().encode(value), encoded.count <= 65_536 else { throw error }
    }
    private static func equalJSON(_ a:JSONValue,_ b:JSONValue) -> Bool {
        switch (a,b) {
        case (.string(let a),.string(let b)): return a.utf8.elementsEqual(b.utf8)
        case (.array(let a),.array(let b)): return a.count == b.count && zip(a,b).allSatisfy { equalJSON($0,$1) }
        case (.object(let a),.object(let b)):
            return a.count == b.count && a.allSatisfy { key,value in b.first(where:{$0.key.utf8.elementsEqual(key.utf8)}).map { equalJSON(value,$0.value) } ?? false }
        default: return a == b
        }
    }
}
