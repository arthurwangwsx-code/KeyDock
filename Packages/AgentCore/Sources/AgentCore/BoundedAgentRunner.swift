import Foundation
import AICore
import ExecutionCore

public enum AgentEvent: Sendable {
    case text(String)
    case toolStarted(AIToolCall)
    case toolFinished(id: String, result: String)
    case usage(AIUsage)
    /// 宿主标记一次成功但未报告用量的请求；不是提供商上报的计费观察。
    case usageUnknown(attemptID: UUID)
    case completed
}

public struct BoundedAgentRunner: Sendable {
    private let provider: any AIProvider
    private let broker: any AgentToolRouting
    private let maxToolCalls: Int
    private let maxTurns: Int
    private let wallTimeout: Duration
    private let maxOutputBytes: Int
    public init(provider: any AIProvider, broker: any AgentToolRouting, maxToolCalls: Int = 20,
                maxTurns: Int = 8, wallTimeout: Duration = .seconds(300), maxOutputBytes: Int = 16_777_216) {
        self.provider = provider; self.broker = broker
        self.maxToolCalls = maxToolCalls; self.maxTurns = maxTurns; self.wallTimeout = wallTimeout
        self.maxOutputBytes = min(16_777_216,max(1,maxOutputBytes))
    }
    public func run(messages: [AIMessage], allowedTools: Set<String>) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard maxToolCalls >= 0, maxTurns > 0, wallTimeout > .zero else { throw AIProviderError.invalidRequest }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await execute(messages: messages, allowedTools: allowedTools, continuation: continuation) }
                        group.addTask {
                            try await Task.sleep(for: wallTimeout)
                            throw AIProviderError.deadlineExceeded
                        }
                        defer { group.cancelAll() }
                        _ = try await group.next()
                    }
                    try Task.checkCancellation()
                    continuation.yield(.completed)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private func execute(messages: [AIMessage], allowedTools: Set<String>,
                         continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation) async throws {
        let available = await broker.definitions()
        guard allowedTools.isSubset(of: Set(available.map(\.name))) else { throw AIProviderError.unknownTool }
        let definitions = available.filter { allowedTools.contains($0.name) }
        var history = messages
        var toolCount = 0
        var outputBytes = 0
        for _ in 0..<maxTurns {
            try Task.checkCancellation()
            var text = ""
            var calls: [AIToolCall] = []
            var completed = false
            let unreportedAttemptID = UUID()
            var receivedUsage = false
            let stream = provider.stream(.init(messages: history, tools: definitions))
            for try await event in stream {
                try Task.checkCancellation()
                guard !completed else { throw AIProviderError.malformedEvent }
                switch event {
                case .text(let delta):
                    outputBytes += delta.utf8.count
                    guard outputBytes <= maxOutputBytes else { throw AIProviderError.outputLimit }
                    text += delta; continuation.yield(.text(delta))
                case .toolCall(let call): calls.append(call)
                case .usage(let usage): receivedUsage = true; continuation.yield(.usage(usage))
                case .completed: completed = true
                }
            }
            guard completed else { throw AIProviderError.truncatedStream }
            if !receivedUsage { continuation.yield(.usageUnknown(attemptID: unreportedAttemptID)) }
            if calls.isEmpty { return }
            toolCount += calls.count
            guard toolCount <= maxToolCalls, Set(calls.map(\.id)).count == calls.count else {
                throw AIProviderError.toolBudgetExceeded
            }
            history.append(.init(role: "assistant", content: text, toolCalls: calls))
            for call in calls {
                try Task.checkCancellation()
                outputBytes += call.name.utf8.count + 4
                guard outputBytes <= maxOutputBytes else { throw AIProviderError.outputLimit }
                continuation.yield(.toolStarted(call))
                let result = try await broker.invoke(call, allowed: allowedTools)
                try Task.checkCancellation()
                outputBytes += result.utf8.count + 1
                guard outputBytes <= maxOutputBytes else { throw AIProviderError.outputLimit }
                continuation.yield(.toolFinished(id: call.id, result: result))
                history.append(.init(role: "tool", content: result, toolCallID: call.id))
            }
        }
        throw AIProviderError.toolBudgetExceeded
    }
}

public enum AgentRunState: String, Codable, Sendable {
    case queued, running, awaitingApproval, paused, succeeded, failed, cancelled, interrupted
    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

public enum AgentRunAction: Sendable {
    case start, requestApproval, approve, deny, pause, succeed, fail, cancel, interrupt, newAttempt
}

public enum AgentRunTransitions {
    public static func apply(_ action: AgentRunAction, to state: AgentRunState) -> AgentRunState? {
        switch (state, action) {
        case (.queued, .start): .running
        case (.queued, .cancel), (.running, .cancel), (.awaitingApproval, .cancel), (.paused, .cancel): .cancelled
        case (.running, .requestApproval): .awaitingApproval
        case (.awaitingApproval, .approve): .running
        case (.awaitingApproval, .deny), (.awaitingApproval, .fail), (.running, .fail): .failed
        case (.running, .pause): .paused
        case (.running, .succeed): .succeeded
        case (.running, .interrupt), (.awaitingApproval, .interrupt): .interrupted
        case (.paused, .newAttempt), (.interrupted, .newAttempt): .queued
        default: nil
        }
    }
}
