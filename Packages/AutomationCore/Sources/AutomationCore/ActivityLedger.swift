import Foundation

public actor ActivityLedger {
    private struct Envelope: Codable { let version: Int; let events: [ActivityEvent] }
    private let persistence: ActivityPersistence
    private let policy: ActivityRetentionPolicy
    private var events: [ActivityEvent]
    private var enabled: Bool
    private var enabledSince: Date?

    public init(persistence: ActivityPersistence, enabled: Bool = false,
                policy: ActivityRetentionPolicy = .init(), now: Date = Date()) throws {
        guard (1...365).contains(policy.days), (1...100_000).contains(policy.maxEvents),
              (512...16 * 1_048_576).contains(policy.maxBytes) else { throw ActivityError.invalidPolicy }
        guard Self.valid(now) else { throw ActivityError.invalidClock }
        let loaded: [ActivityEvent]
        if let data = try persistence.load() {
            guard data.count <= 16 * 1_048_576 else { throw ActivityError.storageTooLarge }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope: Envelope
            do { envelope = try decoder.decode(Envelope.self, from: data) }
            catch { throw ActivityError.corruptStorage }
            guard envelope.version == 1 else { throw ActivityError.unsupportedVersion }
            guard Set(envelope.events.map(\.id)).count == envelope.events.count,
                  envelope.events.allSatisfy(Self.valid) else { throw ActivityError.corruptStorage }
            loaded = envelope.events
        } else { loaded = [] }
        let retained = try Self.bounded(loaded, policy: policy, now: now)
        if retained != loaded { try persistence.save(Self.encode(retained)) }
        self.persistence = persistence; self.policy = policy; self.events = retained
        self.enabled = enabled; self.enabledSince = enabled ? now : nil
    }

    public init(directory: URL, enabled: Bool = false, policy: ActivityRetentionPolicy = .init(), now: Date = Date()) throws {
        try self.init(persistence: .privateJSON(directory: directory, maxLoadBytes: 16 * 1_048_576), enabled: enabled, policy: policy, now: now)
    }

    public func isEnabled() -> Bool { enabled }
    public func setEnabled(_ value: Bool, now: Date = Date()) throws {
        guard Self.valid(now) else { throw ActivityError.invalidClock }
        if value && !enabled { enabledSince = now }
        if !value { enabledSince = nil }
        enabled = value
    }

    /// 暂停时不写入；重新开启只接纳开启之后的新事件，不回填暂停期间事件。
    @discardableResult public func record(_ event: ActivityEvent, now: Date = Date()) throws -> Bool {
        guard enabled else { return false }
        guard Self.valid(now) else { throw ActivityError.invalidClock }
        guard Self.valid(event), event.date <= now.addingTimeInterval(1) else { throw ActivityError.invalidEvent }
        guard let enabledSince, event.date >= enabledSince,
              event.date >= now.addingTimeInterval(-Double(policy.days) * 86_400),
              !events.contains(where: { $0.id == event.id }) else { return false }
        let candidate = try Self.bounded(events + [event], policy: policy, now: now)
        guard candidate.contains(where: { $0.id == event.id }) else { throw ActivityError.capacityExceeded }
        try persistence.save(Self.encode(candidate)); events = candidate
        return true
    }

    public func clear(now: Date = Date()) throws {
        guard Self.valid(now) else { throw ActivityError.invalidClock }
        try persistence.save(Self.encode([])); events = []
        if enabled { enabledSince = now }
    }

    public func report(from: Date, to: Date, now: Date = Date(), topLimit: Int = 10) throws -> ActivityReport {
        guard Self.valid(now) else { throw ActivityError.invalidClock }
        guard Self.valid(from), Self.valid(to), from < to else { throw ActivityError.invalidInterval }
        let candidate = try Self.bounded(events, policy: policy, now: now)
        if candidate != events { try persistence.save(Self.encode(candidate)); events = candidate }
        let selected = events.filter { $0.date >= from && $0.date < to && $0.date <= now }
        let successes = selected.filter { $0.outcome == .succeeded }.count
        let failures = selected.filter { $0.outcome == .failed }.count
        let duration: TimeInterval = selected.reduce(0.0) { $0 + $1.duration }
        let groups = Dictionary(grouping: selected, by: \.commandID)
        var commands: [ActivityCommandAggregate] = []
        for (id, values) in groups {
            let successCount = values.filter { $0.outcome == .succeeded }.count
            let failureCount = values.filter { $0.outcome == .failed }.count
            let total: TimeInterval = values.reduce(0.0) { $0 + $1.duration }
            commands.append(ActivityCommandAggregate(commandID: id, count: values.count,
                succeeded: successCount, failed: failureCount, totalDuration: total))
        }
        commands.sort { left, right in
            if left.count == right.count { return left.commandID < right.commandID }
            return left.count > right.count
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dayGroups = Dictionary(grouping: selected) { formatter.string(from: $0.date) }
        var days: [ActivityDayAggregate] = []
        for (day, values) in dayGroups {
            let successCount = values.filter { $0.outcome == .succeeded }.count
            let failureCount = values.filter { $0.outcome == .failed }.count
            days.append(ActivityDayAggregate(utcDate: day, count: values.count,
                succeeded: successCount, failed: failureCount))
        }
        days.sort { $0.utcDate < $1.utcDate }
        return ActivityReport(from: from, to: to, retainedFrom: now.addingTimeInterval(-Double(policy.days) * 86_400),
                              generatedAt: now, trackingEnabledNow: enabled, coverageIsComplete: false,
                              totalCount: selected.count,
                              outcomeCounts: Dictionary(grouping: selected, by: { $0.outcome.rawValue }).mapValues(\.count),
                              categoryCounts: Dictionary(grouping: selected, by: { $0.category.rawValue }).mapValues(\.count),
                              totalDuration: duration, averageDuration: selected.isEmpty ? nil : duration / Double(selected.count),
                              successRateAmongKnownCompletions: successes + failures == 0 ? nil : Double(successes) / Double(successes + failures),
                              topCommands: Array(commands.prefix(max(0, min(100, topLimit)))), days: days)
    }

    /// 导出仅聚合报告，绝不导出原事件列表、正文或运行参数。
    public func exportAggregate(from: Date, to: Date, now: Date = Date()) throws -> Data {
        let result = try report(from: from, to: to, now: now)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(result)
    }

    private static func valid(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }
    private static func valid(_ event: ActivityEvent) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return !event.commandID.isEmpty && event.commandID.utf8.count <= 200 &&
            event.commandID.unicodeScalars.allSatisfy { allowed.contains($0) } &&
            event.duration.isFinite && event.duration >= 0 && event.duration <= 7 * 86_400 && valid(event.date)
    }
    private static func encode(_ events: [ActivityEvent]) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(version: 1, events: events))
    }
    private static func bounded(_ values: [ActivityEvent], policy: ActivityRetentionPolicy, now: Date) throws -> [ActivityEvent] {
        let cutoff = now.addingTimeInterval(-Double(policy.days) * 86_400)
        var result = values.enumerated().filter { $0.element.date >= cutoff }.sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date }.map(\.element)
        if result.count > policy.maxEvents { result.removeFirst(result.count - policy.maxEvents) }
        if try encode(result).count <= policy.maxBytes { return result }
        var low = 0, high = result.count
        while low < high {
            let mid = (low + high) / 2
            if try encode(Array(result.dropFirst(mid))).count <= policy.maxBytes { high = mid }
            else { low = mid + 1 }
        }
        return Array(result.dropFirst(low))
    }
}
