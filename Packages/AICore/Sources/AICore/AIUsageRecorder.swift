import Foundation

public struct AIRecordedCall: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case running, succeeded, failed, cancelled }
    public let attemptID: UUID
    public let endpointFingerprint: String
    public let model: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var outcome: Outcome
    public let rate: AIRateSnapshot?
    public var rateCorrupt = false
    public var usage: AIUsage?
    public var hasUnknownUsage: Bool
}

extension AIRecordedCall {
    private enum CodingKeys: String, CodingKey { case attemptID, endpointFingerprint, model, startedAt, finishedAt, outcome, rate, rateCorrupt, usage, hasUnknownUsage }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attemptID = try c.decode(UUID.self, forKey: .attemptID)
        endpointFingerprint = try c.decode(String.self, forKey: .endpointFingerprint)
        model = try c.decode(String.self, forKey: .model)
        startedAt = try c.decode(Date.self, forKey: .startedAt); finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        usage = try c.decodeIfPresent(AIUsage.self, forKey: .usage)
        hasUnknownUsage = try c.decode(Bool.self, forKey: .hasUnknownUsage)
        rateCorrupt = (try? c.decodeIfPresent(Bool.self, forKey: .rateCorrupt)) ?? false
        do { rate = try c.decodeIfPresent(AIRateSnapshot.self, forKey: .rate) }
        catch { rate = nil; rateCorrupt = true }
    }
}

public struct AIRecordedUsage: Codable, Equatable, Sendable {
    public var calls: [AIRecordedCall]
    public var overflowed: Bool
    public var incomplete: Bool
    public init(calls: [AIRecordedCall] = [], overflowed: Bool = false, incomplete: Bool = false) { self.calls = calls; self.overflowed = overflowed; self.incomplete = incomplete }
    private enum CodingKeys: String, CodingKey { case calls, overflowed, incomplete }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decode([AIRecordedCall].self, forKey: .calls); overflowed = try c.decode(Bool.self, forKey: .overflowed)
        incomplete = try c.decodeIfPresent(Bool.self, forKey: .incomplete) ?? false
    }
}

/// 有界无正文记录与producer lease；先于yield接收事实，取消消费者不会使已发生的usage消失。
public final class AIUsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    public let frozenRate: AIRateSnapshot?
    private var calls: [UUID: AIRecordedCall] = [:]
    private var accumulators: [UUID: AIUsageAccumulator] = [:]
    private var order: [UUID] = []
    private var workers: Set<UUID> = []
    private var waiters: [CheckedContinuation<AIRecordedUsage, Never>] = []
    private var overflowed = false
    private var sealed = false
    public init(rate: AIRateSnapshot? = nil) { frozenRate = rate }
    public var isClosed: Bool { lock.withLock { sealed } }
    public func beginWorker() -> UUID? {
        lock.withLock { guard !sealed else { return nil }; let id = UUID(); workers.insert(id); return id }
    }
    public func endWorker(_ id: UUID) {
        let completion: ([CheckedContinuation<AIRecordedUsage, Never>], AIRecordedUsage)? = lock.withLock {
            guard workers.remove(id) != nil, workers.isEmpty else { return nil }
            let ready = waiters; waiters.removeAll(); return (ready, snapshotLocked())
        }
        if let (ready, snapshot) = completion { for waiter in ready { waiter.resume(returning: snapshot) } }
    }
    /// 同锁关闭新入口并冻结最终事实；已有attempt的最后观察仍可写入，等待者不能提前取消收口。
    public func closeAndSnapshot() async -> AIRecordedUsage {
        await withCheckedContinuation { continuation in
            let ready: AIRecordedUsage? = lock.withLock {
                sealed = true
                if workers.isEmpty { return snapshotLocked() }
                waiters.append(continuation); return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
    public func beginAttempt(worker: UUID, configuration: AIProviderConfiguration, at date: Date = Date()) -> UUID? {
        lock.withLock {
            guard !sealed, workers.contains(worker), (try? configuration.validate()) != nil else { return nil }
            let id = UUID()
            guard order.count < 128 else { overflowed = true; return id }
            let fingerprint = AIServiceIdentity.fingerprint(configuration.serviceIdentityEndpoint)
            let rate = frozenRate.flatMap { $0.isValid(endpointFingerprint: fingerprint, model: configuration.model) ? $0 : nil }
            calls[id] = .init(attemptID: id, endpointFingerprint: fingerprint, model: configuration.model,
                              startedAt: date, outcome: .running, rate: rate, hasUnknownUsage: true)
            accumulators[id] = AIUsageAccumulator(); order.append(id); return id
        }
    }
    public func observe(_ usage: AIUsage) {
        lock.withLock {
            guard var accumulator = accumulators[usage.attemptID], var call = calls[usage.attemptID], call.outcome == .running else { return }
            do { try accumulator.observe(usage) } catch { accumulator.markUnknown(attemptID: usage.attemptID) }
            call.usage = accumulator.observations.first
            call.hasUnknownUsage = accumulator.hasUnknownUsage
            accumulators[usage.attemptID] = accumulator; calls[usage.attemptID] = call
        }
    }
    public func finishAttempt(_ id: UUID, outcome: AIRecordedCall.Outcome, at date: Date = Date()) {
        lock.withLock {
            guard var call = calls[id], call.outcome == .running, outcome != .running else { return }
            call.outcome = outcome; call.finishedAt = date
            call.hasUnknownUsage = call.hasUnknownUsage || outcome != .succeeded || call.usage == nil
            calls[id] = call
        }
    }
    public func snapshot() -> AIRecordedUsage {
        lock.withLock { snapshotLocked() }
    }
    private func snapshotLocked() -> AIRecordedUsage { .init(calls: order.compactMap { calls[$0] }, overflowed: overflowed) }
}
