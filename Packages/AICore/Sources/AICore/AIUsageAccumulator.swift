import Foundation

public enum AIUsageAccumulatorError: Error, Equatable, Sendable {
    case unsupportedDelta
    case invalidTokenCount
    case conflictingResponseIdentity
    case invalidResponseIdentity
}

public enum AIUsageObservationChange: Equatable, Sendable {
    case inserted, updated, duplicate
}

/// 一次真实请求的身份由 attemptID 决定，responseID 只是随后可补充的提供商身份。
/// 首版仅接受累计快照；没有稳定事件身份的 delta 无法可靠去重，因此明确拒绝。
public struct AIUsageAccumulator: Sendable {
    private var snapshots: [UUID: AIUsage] = [:]
    private var order: [UUID] = []
    /// 保留已知快照，同时标出存在未计入/不一致用量的请求；消费者必须连同这些标记保存。
    public private(set) var unknownAttempts: Set<UUID> = []

    public init() {}
    public var observations: [AIUsage] { order.compactMap { snapshots[$0] } }
    public var hasUnknownUsage: Bool {
        !unknownAttempts.isEmpty || observations.contains { $0.inputTokens == nil || $0.outputTokens == nil }
    }

    @discardableResult public mutating func observe(_ incoming: AIUsage) throws -> AIUsageObservationChange {
        guard incoming.counting == .cumulative else {
            unknownAttempts.insert(incoming.attemptID)
            throw AIUsageAccumulatorError.unsupportedDelta
        }
        guard (incoming.inputTokens ?? 0) >= 0, (incoming.outputTokens ?? 0) >= 0 else {
            unknownAttempts.insert(incoming.attemptID)
            throw AIUsageAccumulatorError.invalidTokenCount
        }
        if let identity = incoming.responseID, identity.isEmpty || identity.utf8.count > 256 {
            unknownAttempts.insert(incoming.attemptID)
            throw AIUsageAccumulatorError.invalidResponseIdentity
        }
        guard var existing = snapshots[incoming.attemptID] else {
            snapshots[incoming.attemptID] = incoming
            order.append(incoming.attemptID)
            return .inserted
        }
        if let oldID = existing.responseID, let newID = incoming.responseID, oldID != newID {
            unknownAttempts.insert(incoming.attemptID)
            throw AIUsageAccumulatorError.conflictingResponseIdentity
        }
        if let responseID = incoming.responseID { existing.responseID = responseID }
        // 缺失字段不擦除已有证据；迟到的旧快照也不降低已知累计值。
        if let value = incoming.inputTokens {
            if let previous = existing.inputTokens, value < previous { unknownAttempts.insert(incoming.attemptID) }
            existing.inputTokens = max(existing.inputTokens ?? value, value)
        }
        if let value = incoming.outputTokens {
            if let previous = existing.outputTokens, value < previous { unknownAttempts.insert(incoming.attemptID) }
            existing.outputTokens = max(existing.outputTokens ?? value, value)
        }
        let change: AIUsageObservationChange = existing == snapshots[incoming.attemptID] ? .duplicate : .updated
        snapshots[incoming.attemptID] = existing
        return change
    }

    /// 请求取消、失败或缺少最终 usage 时可显式标记；已知部分仍保留，未知不冒充零。
    public mutating func markUnknown(attemptID: UUID) {
        unknownAttempts.insert(attemptID)
    }
}
