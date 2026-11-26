import Foundation
import CryptoKit
import ExecutionCore
import AgentCore
import AutomationCore
import AICore

/// 恢复来源的专用v1投影。只返回摘要；正文、参数与环境仅在本次hash期间驻留内存。
/// 不使用模型的默认Codable合同，避免新增字段或Set编码顺序悄悄改变历史身份。
enum RunDefinitionFingerprint {
    private struct Envelope<Value: Encodable>: Encodable {
        let hashSchemaVersion: Int
        let kind: String
        let definition: Value
    }
    private struct Command: Encodable {
        struct Environment: Encodable { let key: String; let value: String }
        let id: UUID, name: String, executable: String, arguments: [String], workingDirectory: String
        let environment: [Environment]
        let timeoutBits: String
        let interactive: Bool, shellMode: Bool
    }
    private struct Action: Encodable {
        struct Shortcut: Encodable { let keyCode: UInt32; let modifiers: UInt32 }
        let id: UUID, name: String, builtinKey: String?, prompt: String, input: String, output: String, modelOverride: String
        let shortcut: Shortcut?
    }
    private struct Agent: Encodable {
        let id: UUID, version: Int, name: String, instructions: String, modelOverride: String
        let allowedCommandIDs: [UUID], allowedMCPServerIDs: [UUID], allowedMCPToolNames: [String]
        let maxToolCalls: Int, maxTurns: Int, timeoutSeconds: Int
    }
    private struct ActionV2: Encodable { let legacy: Action; let scene: AIScene?; let modelOptions: AIModelOptions? }
    private struct AgentV2: Encodable { let legacy: Agent; let modelOptions: AIModelOptions }
    private struct AgentV3: Encodable { let legacy: Agent; let modelOptions: AIModelOptions?; let maxRunTokens: Int; let tokenBudgetPolicyVersion: Int }
    private struct Workflow: Encodable {
        struct Step: Encodable {
            let id: UUID
            let operation: String, targetID: UUID?, transform: String?
            let input: String, literal: String?
            init(_ value: WorkflowStep) {
                id = value.id
                switch value.operation {
                case .savedCommand(let id): operation = "savedCommand"; targetID = id; transform = nil
                case .aiAction(let id): operation = "aiAction"; targetID = id; transform = nil
                case .transform(let value): operation = "transform"; targetID = nil; transform = value.rawValue
                case .manualInput: operation = "manualInput"; targetID = nil; transform = nil
                }
                switch value.input {
                case .workflowInput: input = "workflowInput"; literal = nil
                case .previousOutput: input = "previousOutput"; literal = nil
                case .literal(let value): input = "literal"; literal = value
                }
            }
        }
        let id: UUID, name: String, version: Int, steps: [Step]
    }
    static func reference(_ value: SavedCommand) throws -> RunDefinitionReference {
        guard value.timeout.isFinite, value.timeout > 0, value.timeout <= 86_400 else { throw SavedCommandValidationError.invalidTimeout }
        let projected = Command(id: value.id, name: value.name, executable: value.executable,
            arguments: value.arguments, workingDirectory: value.workingDirectory,
            environment: value.environment.map { .init(key: $0.key, value: $0.value) }.sorted { utf8Less($0.key, $1.key) },
            timeoutBits: String(value.timeout.bitPattern, radix: 16), interactive: value.interactive, shellMode: value.shellMode)
        return try reference(kind: .savedCommand, id: value.id, definition: projected)
    }
    static func reference(_ value: AIActionPreset) throws -> RunDefinitionReference {
        let projected = Action(id: value.id, name: value.name, builtinKey: value.builtinKey, prompt: value.prompt,
            input: value.input.rawValue, output: value.output.rawValue, modelOverride: value.modelOverride,
            shortcut: value.shortcut.map { .init(keyCode: $0.keyCode, modifiers: $0.modifiers) })
        if value.modelOptions != nil || (value.scene != nil && value.scene != .text) {
            return try reference(kind: .aiAction, id: value.id, definition: ActionV2(legacy: projected, scene: value.scene, modelOptions: value.modelOptions), projectionVersion: 2)
        }
        return try reference(kind: .aiAction, id: value.id, definition: projected)
    }
    static func reference(_ value: AgentDefinition) throws -> RunDefinitionReference {
        let projected = Agent(id: value.id, version: value.version, name: value.name, instructions: value.instructions, modelOverride: value.modelOverride,
            allowedCommandIDs: value.allowedCommandIDs.sorted { $0.uuidString < $1.uuidString },
            allowedMCPServerIDs: value.allowedMCPServerIDs.sorted { $0.uuidString < $1.uuidString },
            allowedMCPToolNames: value.allowedMCPToolNames.sorted(by: utf8Less), maxToolCalls: value.maxToolCalls,
            maxTurns: value.maxTurns, timeoutSeconds: value.timeoutSeconds)
        if let threshold = value.maxRunTokens {
            return try reference(kind: .agent, id: value.id, version: value.version,
                definition: AgentV3(legacy: projected, modelOptions: value.modelOptions, maxRunTokens: threshold,
                    tokenBudgetPolicyVersion: RunTokenBudgetSnapshot.currentPolicyVersion), projectionVersion: 3)
        }
        if let options = value.modelOptions {
            return try reference(kind: .agent, id: value.id, version: value.version, definition: AgentV2(legacy: projected, modelOptions: options), projectionVersion: 2)
        }
        return try reference(kind: .agent, id: value.id, version: value.version, definition: projected)
    }
    static func reference(_ value: WorkflowDefinition) throws -> RunDefinitionReference {
        try reference(kind: .workflow, id: value.id, version: value.version,
            definition: Workflow(id: value.id, name: value.name, version: value.version, steps: value.steps.map(Workflow.Step.init)))
    }
    private static func reference<Value: Encodable>(kind: RecoverableRunKind, id: UUID, version: Int? = nil, definition: Value, projectionVersion: Int = 1) throws -> RunDefinitionReference {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(hashSchemaVersion: projectionVersion, kind: kind.rawValue, definition: definition))
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let result = RunDefinitionReference(kind: kind, definitionID: id, definitionVersion: version, fingerprint: fingerprint)
        guard result.isValid else { throw InvocationStoreError.invalidMetadata }
        return result
    }
    private static func utf8Less(_ left: String, _ right: String) -> Bool { left.utf8.lexicographicallyPrecedes(right.utf8) }
}

/// 仅按类型与准确ID寻找唯一的当前保存定义；缺失、重复或改换类型不会降级为任意commandID匹配。
enum SavedRunDefinition: Sendable {
    case command(SavedCommand), action(AIActionPreset), agent(AgentDefinition), workflow(WorkflowDefinition)
    var reference: RunDefinitionReference {
        get throws {
            switch self {
            case .command(let value): try RunDefinitionFingerprint.reference(value)
            case .action(let value): try RunDefinitionFingerprint.reference(value)
            case .agent(let value): try RunDefinitionFingerprint.reference(value)
            case .workflow(let value): try RunDefinitionFingerprint.reference(value)
            }
        }
    }
    var name: String {
        switch self { case .command(let value): value.name; case .action(let value): value.displayName; case .agent(let value): value.name; case .workflow(let value): value.name }
    }
    static func resolve(_ reference: RunDefinitionReference, in configuration: AppConfiguration) -> Self? {
        func only<Value: Identifiable>(_ values: [Value]) -> Value? where Value.ID == UUID {
            let matches = values.filter { $0.id == reference.definitionID }; return matches.count == 1 ? matches[0] : nil
        }
        switch reference.kind {
        case .savedCommand: return only(configuration.savedCommands).map(Self.command)
        case .aiAction: return only(configuration.aiActions).map(Self.action)
        case .agent: return only(configuration.agents).map(Self.agent)
        case .workflow: return only(configuration.workflows).map(Self.workflow)
        }
    }
}
