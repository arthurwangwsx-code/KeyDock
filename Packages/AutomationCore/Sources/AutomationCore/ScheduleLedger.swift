import Foundation

/// 只负责计划元数据和claim，不运行Workflow、不创建daemon、不提升无人值守权限。
public actor ScheduleLedger {
    private struct Envelope: Codable { let version: Int; let records: [ScheduleSnapshot] }
    public nonisolated let initialSnapshots: [ScheduleSnapshot]
    private let persistence: SchedulePersistence
    private let maxRecords: Int
    private let maxBytes: Int
    private var records: [UUID: ScheduleSnapshot]
    private var suspendedForSession: Set<UUID> = []
    private var invalidatedForSession: Set<UUID> = []

    public init(persistence: SchedulePersistence, now: Date, maxRecords: Int = 200, maxBytes: Int = 1_048_576) throws {
        guard (1...1_000).contains(maxRecords), (512...2 * 1_048_576).contains(maxBytes) else { throw ScheduleError.invalidPolicy }
        guard ScheduleCalendar.valid(now) else { throw ScheduleError.invalidClock }
        var values: [UUID: ScheduleSnapshot] = [:]
        if let data = try persistence.load() {
            guard data.count <= 2 * 1_048_576 else { throw ScheduleError.storageTooLarge }
            let envelope: Envelope
            do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
            catch { throw ScheduleError.corruptStorage }
            guard envelope.version == 1 else { throw ScheduleError.unsupportedVersion }
            guard envelope.records.count <= maxRecords else { throw ScheduleError.capacityExceeded }
            var seenAttempts: Set<UUID> = []
            for record in envelope.records {
                guard values[record.id] == nil else { throw ScheduleError.corruptStorage }
                do { try Self.validate(record) } catch { throw ScheduleError.corruptStorage }
                for attempt in [record.activeAttempt, record.lastAttempt].compactMap({ $0 }) {
                    guard seenAttempts.insert(attempt.id).inserted else { throw ScheduleError.corruptStorage }
                }
                values[record.id] = record
            }
        }
        var recovered = false
        for (id, var record) in values {
            if var attempt = record.activeAttempt {
                attempt.outcome = .unknown; attempt.finishedAt = now
                record.lastAttempt = attempt; record.activeAttempt = nil; record.reviewRequired = true
                record.nextFireAt = try ScheduleCalendar.nextFire(for: record.definition.trigger, after: now, anchor: attempt.scheduledFireAt)
                values[id] = record; recovered = true
            }
        }
        if recovered { try persistence.save(Self.encode(values, maxBytes: maxBytes)) }
        self.persistence = persistence; self.maxRecords = maxRecords; self.maxBytes = maxBytes; records = values
        initialSnapshots = values.values.sorted{$0.id.uuidString < $1.id.uuidString}
    }
    public init(directory: URL, now: Date, maxRecords: Int = 200, maxBytes: Int = 1_048_576) throws {
        try self.init(persistence: .privateJSON(directory: directory), now: now, maxRecords: maxRecords, maxBytes: maxBytes)
    }
    public func snapshots() -> [ScheduleSnapshot] {
        records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func isSuspendedForSession(id: UUID) -> Bool { suspendedForSession.contains(id) }
    /// 新定义revision必须为1；编辑必须为当前revision+1，旧编辑器不能覆盖新版本。
    @discardableResult public func upsert(_ definition: ScheduleDefinition, now: Date) throws -> ScheduleMutation {
        guard ScheduleCalendar.valid(now) else { throw ScheduleError.invalidClock }
        try Self.validate(definition)
        var candidate = records
        let prior = records[definition.id]
        guard definition.revision == (prior.map { $0.definition.revision + 1 } ?? 1) else { throw ScheduleError.revisionConflict }
        guard prior != nil || records.count < maxRecords else { throw ScheduleError.capacityExceeded }
        // 暂停的本会话安全屏障优先于磁盘写；写失败仍抛错，重启风险由宿主明确告知。
        if !definition.enabled, prior?.definition.enabled == true {
            suspendedForSession.insert(definition.id)
            if let active = prior?.activeAttempt { invalidatedForSession.insert(active.id) }
        }
        var next = ScheduleSnapshot(definition: definition, nextFireAt: try ScheduleCalendar.nextFire(for: definition.trigger, after: now))
        next.lastAttempt = prior?.lastAttempt; next.lastClaimedKey = prior?.lastClaimedKey
        next.reviewRequired = prior?.reviewRequired ?? false
        let invalidated = prior?.activeAttempt?.id
        if var attempt = prior?.activeAttempt {
            attempt.outcome = .unknown; attempt.finishedAt = now
            next.lastAttempt = attempt; next.reviewRequired = true
        }
        candidate[definition.id] = next
        try commit(candidate)
        if definition.enabled { suspendedForSession.remove(definition.id) }
        if let invalidated { invalidatedForSession.remove(invalidated) }
        return ScheduleMutation(snapshot: next, invalidatedAttemptID: invalidated)
    }
    @discardableResult public func setEnabled(_ enabled: Bool, id: UUID, expectedRevision: Int, now: Date) throws -> ScheduleMutation {
        guard let record = records[id] else { throw ScheduleError.notFound }
        guard record.definition.revision == expectedRevision else { throw ScheduleError.revisionConflict }
        if record.definition.enabled == enabled, !suspendedForSession.contains(id) { return ScheduleMutation(snapshot: record, invalidatedAttemptID: nil) }
        let old = record.definition
        return try upsert(ScheduleDefinition(id: old.id, name: old.name, workflowID: old.workflowID,
            enabled: enabled, trigger: old.trigger, revision: old.revision + 1, authorizationFingerprint:old.authorizationFingerprint), now: now)
    }
    /// 只有显式检查unknown后调用；不改变definition.enabled，原本禁用的计划仍需单独启用。
    @discardableResult public func acknowledgeUnknown(id: UUID, expectedRevision: Int, now: Date) throws -> ScheduleSnapshot {
        guard ScheduleCalendar.valid(now) else { throw ScheduleError.invalidClock }
        guard var record = records[id] else { throw ScheduleError.notFound }
        guard record.definition.revision == expectedRevision else { throw ScheduleError.revisionConflict }
        guard record.reviewRequired else { throw ScheduleError.reviewNotRequired }
        record.reviewRequired = false
        record.nextFireAt = try ScheduleCalendar.nextFire(for: record.definition.trigger, after: now)
        var candidate = records; candidate[id] = record
        try commit(candidate); return record
    }
    /// 返回失效的活动attempt ID，宿主继续跟踪既有真实运行；删除定义不等于撤回副作用。
    @discardableResult public func remove(id: UUID, expectedRevision: Int) throws -> UUID? {
        guard let record = records[id] else { throw ScheduleError.notFound }
        guard record.definition.revision == expectedRevision else { throw ScheduleError.revisionConflict }
        suspendedForSession.insert(id)
        if let active = record.activeAttempt { invalidatedForSession.insert(active.id) }
        var candidate = records; candidate.removeValue(forKey: id)
        try commit(candidate)
        suspendedForSession.remove(id)
        if let active = record.activeAttempt { invalidatedForSession.remove(active.id) }
        return record.activeAttempt?.id
    }
    /// 两组目录都必须由宿主当前能力检查计算；缺失引用或需要审批时不claim、不制造假失败。
    public func claimDue(now: Date, availableWorkflowIDs: Set<UUID>, unattendedWorkflowIDs: Set<UUID>, authorizedScheduleIDs: Set<UUID>? = nil, limit: Int = 8) throws -> [ScheduleAttempt] {
        guard ScheduleCalendar.valid(now) else { throw ScheduleError.invalidClock }
        guard (1...32).contains(limit) else { throw ScheduleError.invalidPolicy }
        let due = records.values.filter {
            $0.definition.enabled && (authorizedScheduleIDs?.contains($0.id) ?? true) && !suspendedForSession.contains($0.id) && !$0.reviewRequired && $0.activeAttempt == nil && $0.nextFireAt <= now &&
            availableWorkflowIDs.contains($0.definition.workflowID) && unattendedWorkflowIDs.contains($0.definition.workflowID)
        }.sorted {
            if $0.nextFireAt != $1.nextFireAt { return $0.nextFireAt < $1.nextFireAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var candidate = records, claims: [ScheduleAttempt] = []
        for var record in due.prefix(limit) {
            let attempt = ScheduleAttempt(definition: record.definition, fireAt: record.nextFireAt, now: now)
            guard record.lastClaimedKey != attempt.idempotencyKey else { continue }
            record.activeAttempt = attempt; record.lastClaimedKey = attempt.idempotencyKey
            candidate[record.id] = record; claims.append(attempt)
        }
        if !claims.isEmpty { try commit(candidate) }
        return claims
    }
    /// 已知失败也只推进下一计划点，绝不对当前计划点自动重试；迟到完成返回false。
    @discardableResult public func complete(attemptID: UUID, outcome: ScheduleAttemptOutcome, now: Date) throws -> Bool {
        guard ScheduleCalendar.valid(now) else { throw ScheduleError.invalidClock }
        guard !invalidatedForSession.contains(attemptID),
              let original = records.values.first(where: { $0.activeAttempt?.id == attemptID }),
              var attempt = original.activeAttempt, original.definition.revision == attempt.definitionRevision else { return false }
        var record = original
        attempt.outcome = outcome; attempt.finishedAt = now
        record.lastAttempt = attempt; record.activeAttempt = nil
        record.reviewRequired = outcome == .unknown
        record.nextFireAt = try ScheduleCalendar.nextFire(for: record.definition.trigger, after: now, anchor: attempt.scheduledFireAt)
        var candidate = records; candidate[record.id] = record
        try commit(candidate); return true
    }
    private func commit(_ candidate: [UUID: ScheduleSnapshot]) throws {
        try persistence.save(Self.encode(candidate, maxBytes: maxBytes)); records = candidate
    }
    private static func encode(_ values: [UUID: ScheduleSnapshot], maxBytes: Int) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Date默认以referenceDate Double编码，保留计划点bitPattern，避免幂等键跨重启漂移。
        let data = try encoder.encode(Envelope(version: 1, records: values.values.sorted { $0.id.uuidString < $1.id.uuidString }))
        guard data.count <= maxBytes else { throw ScheduleError.capacityExceeded }
        return data
    }
    private static func validate(_ definition: ScheduleDefinition) throws {
        guard !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              definition.name.utf8.count <= 200,
              !definition.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), definition.revision > 0, definition.revision < Int.max else { throw ScheduleError.invalidDefinition }
        try ScheduleCalendar.validate(definition.trigger)
    }
    private static func validate(_ record: ScheduleSnapshot) throws {
        try validate(record.definition)
        guard ScheduleCalendar.valid(record.nextFireAt), record.lastClaimedKey.map({ $0.utf8.count <= 160 }) != false else { throw ScheduleError.corruptStorage }
        if let active = record.activeAttempt {
            guard active.scheduleID == record.id, active.workflowID == record.definition.workflowID,
                  active.definitionRevision == record.definition.revision, active.outcome == nil, active.finishedAt == nil,
                  active.scheduledFireAt == record.nextFireAt, record.lastClaimedKey == active.idempotencyKey,
                  valid(active), !record.reviewRequired else { throw ScheduleError.corruptStorage }
        }
        if let last = record.lastAttempt {
            guard last.scheduleID == record.id, last.definitionRevision <= record.definition.revision,
                  last.outcome != nil, last.finishedAt != nil, valid(last) else { throw ScheduleError.corruptStorage }
        }
    }
    private static func valid(_ attempt: ScheduleAttempt) -> Bool {
        attempt.definitionRevision > 0 && ScheduleCalendar.valid(attempt.claimedAt) && ScheduleCalendar.valid(attempt.scheduledFireAt) &&
        attempt.claimedAt >= attempt.scheduledFireAt &&
        attempt.finishedAt.map(ScheduleCalendar.valid) != false &&
        attempt.idempotencyKey == ScheduleAttempt.key(scheduleID: attempt.scheduleID, revision: attempt.definitionRevision, fireAt: attempt.scheduledFireAt)
    }
}
