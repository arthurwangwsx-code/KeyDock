import Foundation

public enum ScheduleTrigger: Codable, Sendable, Equatable {
    case interval(seconds: TimeInterval)
    case daily(hour: Int, minute: Int, timeZoneID: String)
}
public struct ScheduleDefinition: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let workflowID: UUID
    public let enabled: Bool
    public let trigger: ScheduleTrigger
    public let revision: Int
    public let authorizationFingerprint: String?
    public init(id: UUID = UUID(), name: String, workflowID: UUID, enabled: Bool = false,
                trigger: ScheduleTrigger, revision: Int = 1, authorizationFingerprint: String? = nil) {
        self.id = id; self.name = name; self.workflowID = workflowID; self.enabled = enabled
        self.trigger = trigger; self.revision = revision; self.authorizationFingerprint = authorizationFingerprint
    }
}
public enum ScheduleAttemptOutcome: String, Codable, Sendable { case succeeded, failed, cancelled, unknown }
/// 只包含计划点和运行身份，不保存Workflow输入、正文、argv或凭据。
public struct ScheduleAttempt: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let scheduleID: UUID
    public let workflowID: UUID
    public let definitionRevision: Int
    public let scheduledFireAt: Date
    public let claimedAt: Date
    public let idempotencyKey: String
    public internal(set) var outcome: ScheduleAttemptOutcome?
    public internal(set) var finishedAt: Date?
    init(id: UUID = UUID(), definition: ScheduleDefinition, fireAt: Date, now: Date) {
        self.id = id; scheduleID = definition.id; workflowID = definition.workflowID
        definitionRevision = definition.revision; scheduledFireAt = fireAt; claimedAt = now
        idempotencyKey = Self.key(scheduleID: definition.id, revision: definition.revision, fireAt: fireAt)
        outcome = nil; finishedAt = nil
    }
    static func key(scheduleID: UUID, revision: Int, fireAt: Date) -> String {
        scheduleID.uuidString.lowercased() + ":" + String(revision) + ":" + String(fireAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }
}
public struct ScheduleSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { definition.id }
    public internal(set) var definition: ScheduleDefinition
    public internal(set) var nextFireAt: Date
    public internal(set) var activeAttempt: ScheduleAttempt?
    public internal(set) var lastAttempt: ScheduleAttempt?
    public internal(set) var lastClaimedKey: String?
    /// 未知副作用必须由用户检查后显式acknowledge，不能换一个计划点继续自动叠加。
    public internal(set) var reviewRequired: Bool
    init(definition: ScheduleDefinition, nextFireAt: Date) {
        self.definition = definition; self.nextFireAt = nextFireAt
        activeAttempt = nil; lastAttempt = nil; lastClaimedKey = nil; reviewRequired = false
    }
}
public struct ScheduleMutation: Sendable, Equatable {
    public let snapshot: ScheduleSnapshot
    /// 宿主据此取消／观察既有任务；它不表示副作用已经收口。
    public let invalidatedAttemptID: UUID?
}
public enum ScheduleError: Error, Equatable, Sendable {
    case invalidDefinition, invalidTrigger, invalidClock, invalidPolicy
    case notFound, revisionConflict, capacityExceeded, invalidStorage, storageTooLarge
    case corruptStorage, unsupportedVersion, reviewNotRequired
}
