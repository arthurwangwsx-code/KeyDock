import Foundation

/// 仅用于本进程的恢复读取，不持久化，也不携带执行权。
struct UsageRestoreReadTicket: Sendable {
    fileprivate let owner: UUID
    fileprivate let generation: UInt64
    fileprivate let admitted: Bool
    fileprivate let retention: AIUsageRetentionRead
}

struct UsageRestoreReadFence: Sendable {
    private let owner = UUID()
    func capture(generation: UInt64, isClearing: Bool, retention: AIUsageRetentionRead = .init(epoch: 0, admitted: true)) -> UsageRestoreReadTicket {
        .init(owner: owner, generation: generation, admitted: !isClearing, retention: retention)
    }
    func accepts(_ ticket: UsageRestoreReadTicket?, generation: UInt64, isClearing: Bool) -> Bool {
        guard let ticket else { return false }
        return ticket.owner == owner && ticket.admitted && ticket.generation == generation && !isClearing
    }
}

extension WorkbenchModel {
    func captureUsageRestoreRead() -> UsageRestoreReadTicket {
        usageRestoreReadFence.capture(generation: usageHistoryGeneration, isClearing: isClearingUsage || isShuttingDown || isDesktopReview,
            retention: usageMetadataStore.retentionFence.current)
    }
    func acceptsUsageRestoreRead(_ ticket: UsageRestoreReadTicket?) -> Bool {
        guard !isShuttingDown, !isDesktopReview, let ticket,
            usageMetadataStore.retentionFence.accepts(ticket.retention) else { return false }
        return usageRestoreReadFence.accepts(ticket, generation: usageHistoryGeneration, isClearing: isClearingUsage)
    }
}
