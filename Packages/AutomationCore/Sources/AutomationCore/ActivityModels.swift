import Foundation

public enum ActivityCategory: String, Codable, Sendable, CaseIterable {
    case application, window, command, ai, agent, workflow, clipboard, utility
}

public enum ActivityOutcome: String, Codable, Sendable, CaseIterable {
    case succeeded, failed, cancelled, interrupted, unknown
}

/// 只接受稳定命令ID与元数据；不得在ID中放正文、argv、路径、窗口标题或凭据。
public struct ActivityEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let commandID: String
    public let category: ActivityCategory
    public let outcome: ActivityOutcome
    public let duration: TimeInterval
    public let date: Date
    public init(id: UUID = UUID(), commandID: String, category: ActivityCategory,
                outcome: ActivityOutcome, duration: TimeInterval, date: Date = Date()) {
        self.id = id; self.commandID = commandID; self.category = category
        self.outcome = outcome; self.duration = duration; self.date = date
    }
}

public struct ActivityRetentionPolicy: Sendable, Equatable {
    public let days: Int
    public let maxEvents: Int
    public let maxBytes: Int
    public init(days: Int = 30, maxEvents: Int = 5_000, maxBytes: Int = 4 * 1_048_576) {
        self.days = days; self.maxEvents = maxEvents; self.maxBytes = maxBytes
    }
}

public struct ActivityCommandAggregate: Codable, Sendable, Equatable {
    public let commandID: String
    public let count: Int
    public let succeeded: Int
    public let failed: Int
    public let totalDuration: TimeInterval
}

public struct ActivityDayAggregate: Codable, Sendable, Equatable {
    /// UTC日键；展示本地日统计时宿主应显式提供所选时区，不能混用口径。
    public let utcDate: String
    public let count: Int
    public let succeeded: Int
    public let failed: Int
}

public struct ActivityReport: Codable, Sendable, Equatable {
    public let from: Date
    /// 半开区间：[from, to)。
    public let to: Date
    public let retainedFrom: Date
    public let generatedAt: Date
    public let trackingEnabledNow: Bool
    /// 仅反映已记录事件，无法证明所有任务均被采集；不能宣称100%覆盖。
    public let coverageIsComplete: Bool
    public let totalCount: Int
    public let outcomeCounts: [String: Int]
    public let categoryCounts: [String: Int]
    public let totalDuration: TimeInterval
    public let averageDuration: TimeInterval?
    /// 仅在成功与失败两个已知完成结果中计算；取消、中断和unknown不记为失败或零费用。
    public let successRateAmongKnownCompletions: Double?
    public let topCommands: [ActivityCommandAggregate]
    public let days: [ActivityDayAggregate]
}

public enum ActivityError: Error, Equatable, Sendable {
    case invalidPolicy, invalidClock, invalidInterval, invalidEvent, invalidStorage
    case unsupportedVersion, corruptStorage, storageTooLarge, capacityExceeded
}
