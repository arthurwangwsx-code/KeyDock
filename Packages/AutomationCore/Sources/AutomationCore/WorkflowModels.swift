import Foundation

public enum WorkflowTextTransform: String, Codable, Sendable, CaseIterable { case trim, uppercase, lowercase }
public enum WorkflowInputBinding: Codable, Sendable, Equatable {
    case workflowInput
    case previousOutput
    /// 字面值只是输入数据，不能作为可执行代码或额外授权。
    case literal(String)
}
public enum WorkflowOperation: Codable, Sendable, Equatable {
    case savedCommand(UUID)
    case aiAction(UUID)
    case transform(WorkflowTextTransform)
    case manualInput
}
public struct WorkflowStep: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var operation: WorkflowOperation
    public var input: WorkflowInputBinding
    public init(id: UUID = UUID(), operation: WorkflowOperation, input: WorkflowInputBinding = .workflowInput) {
        self.id = id; self.operation = operation; self.input = input
    }
}
public struct WorkflowDefinition: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var version: Int
    public var steps: [WorkflowStep]
    public init(id: UUID = UUID(), name: String, version: Int = 1, steps: [WorkflowStep]) {
        self.id = id; self.name = name; self.version = version; self.steps = steps
    }
}
public struct WorkflowLimits: Sendable, Equatable {
    public let maxSteps: Int
    public let wallTimeout: TimeInterval
    public let maxInputBytes: Int
    /// 全部步骤输出的累计字节预算，不是每步重新获得一份额度。
    public let maxOutputBytes: Int
    public init(maxSteps: Int = 20, wallTimeout: TimeInterval = 300,
                maxInputBytes: Int = 131_072, maxOutputBytes: Int = 1_048_576) {
        self.maxSteps = maxSteps; self.wallTimeout = wallTimeout
        self.maxInputBytes = maxInputBytes; self.maxOutputBytes = maxOutputBytes
    }
}

/// 只能经Compiler生成。定义与预算按值冻结，宿主闭包还必须捕获真实Command／AIAction配置快照。
public struct WorkflowPlan: Sendable, Equatable {
    public let definition: WorkflowDefinition
    public let limits: WorkflowLimits
    public let allowsInteraction: Bool
    init(definition: WorkflowDefinition, limits: WorkflowLimits, allowsInteraction: Bool) {
        self.definition = definition; self.limits = limits; self.allowsInteraction = allowsInteraction
    }
}
public enum WorkflowCompileError: Error, Sendable, Equatable {
    case invalidName, invalidVersion, emptySteps, invalidLimits, tooManySteps, duplicateStepID
    case missingCommand(UUID), missingAIAction(UUID), previousOutputUnavailable(Int)
    case literalTooLarge(Int), interactionNotAllowed(Int), duplicateCatalogID
}
public enum WorkflowCompiler {
    public static func compile(_ definition: WorkflowDefinition,
                               availableCommandIDs: Set<UUID>, availableAIActionIDs: Set<UUID>,
                               limits: WorkflowLimits = .init(), allowsInteraction: Bool = true) throws -> WorkflowPlan {
        guard !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              definition.name.utf8.count <= 200 else { throw WorkflowCompileError.invalidName }
        guard definition.version > 0 else { throw WorkflowCompileError.invalidVersion }
        guard (1...100).contains(limits.maxSteps), limits.wallTimeout.isFinite,
              limits.wallTimeout > 0 && limits.wallTimeout <= 3_600,
              (1...1_048_576).contains(limits.maxInputBytes),
              (1...4 * 1_048_576).contains(limits.maxOutputBytes) else { throw WorkflowCompileError.invalidLimits }
        guard !definition.steps.isEmpty else { throw WorkflowCompileError.emptySteps }
        guard definition.steps.count <= limits.maxSteps else { throw WorkflowCompileError.tooManySteps }
        guard Set(definition.steps.map(\.id)).count == definition.steps.count else { throw WorkflowCompileError.duplicateStepID }
        for (index, step) in definition.steps.enumerated() {
            switch step.input {
            case .previousOutput where index == 0: throw WorkflowCompileError.previousOutputUnavailable(index)
            case .literal(let value) where value.utf8.count > limits.maxInputBytes: throw WorkflowCompileError.literalTooLarge(index)
            default: break
            }
            switch step.operation {
            case .savedCommand(let id) where !availableCommandIDs.contains(id): throw WorkflowCompileError.missingCommand(id)
            case .aiAction(let id) where !availableAIActionIDs.contains(id): throw WorkflowCompileError.missingAIAction(id)
            case .manualInput where !allowsInteraction: throw WorkflowCompileError.interactionNotAllowed(index)
            default: break
            }
        }
        return WorkflowPlan(definition: definition, limits: limits, allowsInteraction: allowsInteraction)
    }
}

public enum WorkflowHostOutcome: String, Codable, Sendable { case succeeded, failed, cancelled, unknown }
public struct WorkflowHostRequest: Sendable, Equatable {
    public let runID: UUID
    public let definitionID: UUID
    public let definitionVersion: Int
    public let stepID: UUID
    public let stepIndex: Int
    public let operation: WorkflowOperation
    public let input: String
    /// 明确是调用者的运行模式；不能因为当前有窗口就临时升级为交互式。
    public let allowsInteraction: Bool
}
public struct WorkflowHostResult: Sendable, Equatable {
    public let outcome: WorkflowHostOutcome
    /// 正文仅沿内存返回，不会进入checkpoint或Core持久化。
    public let output: String
    public init(outcome: WorkflowHostOutcome, output: String = "") { self.outcome = outcome; self.output = output }
}
/// 宿主必须在真实副作用前写既有intent，并把Task取消传播到网络／进程；Core不会重试这个闭包。
public typealias WorkflowHostOperation = @Sendable (WorkflowHostRequest) async throws -> WorkflowHostResult
public enum WorkflowRunOutcome: String, Codable, Sendable { case succeeded, failed, cancelled, timedOut, unknown }
public enum WorkflowStopReason: String, Codable, Sendable {
    case inputLimit, outputLimit, hostFailed, hostCancelled, hostUnknown, hostThrew, cancelled, wallTimeout
}
public enum WorkflowCheckpointPhase: String, Codable, Sendable { case running, succeeded, failed, cancelled, timedOut, unknown }
/// 只投影元数据，无输入／输出正文。它不是新任务数据库，也不替代宿主的durable intent。
public struct WorkflowCheckpoint: Codable, Sendable, Equatable {
    public let runID: UUID
    public let definitionID: UUID
    public let definitionVersion: Int
    public let sequence: Int
    public let stepIndex: Int
    public let stepID: UUID
    public let phase: WorkflowCheckpointPhase
    public let inputBytes: Int
    public let outputBytes: Int
    public let totalOutputBytes: Int
    public let reason: WorkflowStopReason?
}
public typealias WorkflowCheckpointObserver = @Sendable (WorkflowCheckpoint) -> Void
public struct WorkflowRunResult: Sendable, Equatable {
    public let runID: UUID
    public let outcome: WorkflowRunOutcome
    public let output: String
    public let completedSteps: Int
    public let stoppedAtStepIndex: Int?
    public let reason: WorkflowStopReason?
    /// 超时／取消可能先于真实宿主任务收口；宿主继续保留其own receipt与容量reservation，不能重放。
    public let hasUncertainHostOutcome: Bool
    public let checkpoints: [WorkflowCheckpoint]
}
