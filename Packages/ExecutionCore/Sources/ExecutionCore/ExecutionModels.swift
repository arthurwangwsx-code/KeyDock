import Foundation

public struct SavedCommand: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]
    public var timeout: TimeInterval
    public var interactive: Bool
    /// 只标记已明确选择解释器的命令；runner 不会拼接或改写 argv。
    public var shellMode: Bool

    public init(
        id: UUID = UUID(), name: String, executable: String, arguments: [String] = [],
        workingDirectory: String = NSHomeDirectory(), environment: [String: String] = [:],
        timeout: TimeInterval = 60, interactive: Bool = false, shellMode: Bool = false
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.interactive = interactive
        self.shellMode = shellMode
    }
}

public enum ExecutionState: String, Codable, Sendable, CaseIterable {
    case queued, running, succeeded, failed, cancelled, timedOut, interrupted

    public var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        default: true
        }
    }
}

public struct ProcessResult: Codable, Sendable, Equatable {
    public let state: ExecutionState
    public let exitCode: Int32?
    /// 稳定的本地化键；原始输出和敏感参数不进入结果元数据。
    public let message: String

    public init(state: ExecutionState, exitCode: Int32? = nil, message: String = "") {
        self.state = state
        self.exitCode = exitCode
        self.message = message
    }
}

public enum ProcessEvent: Sendable, Equatable {
    case started(Int32)
    case output(String, isError: Bool)
    case finished(ProcessResult)
}
