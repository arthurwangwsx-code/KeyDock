import Foundation

/// 仅用于本进程的恢复读取，不持久化，也不携带执行权。
struct UsageRestoreReadTicket: Sendable {
    fileprivate let owner: UUID
    fileprivate let generation: UInt64
    fileprivate let admitted: Bool
}

struct UsageRestoreReadFence: Sendable {
    private let owner = UUID()
    func capture(generation: UInt64, isClearing: Bool) -> UsageRestoreReadTicket {
        .init(owner: owner, generation: generation, admitted: !isClearing)
    }
    func accepts(_ ticket: UsageRestoreReadTicket?, generation: UInt64, isClearing: Bool) -> Bool {
        guard let ticket else { return false }
        return ticket.owner == owner && ticket.admitted && ticket.generation == generation && !isClearing
    }
}

extension WorkbenchModel {
    func captureUsageRestoreRead() -> UsageRestoreReadTicket {
        usageRestoreReadFence.capture(generation: usageHistoryGeneration, isClearing: isClearingUsage || isShuttingDown || isDesktopReview)
    }
    func acceptsUsageRestoreRead(_ ticket: UsageRestoreReadTicket?) -> Bool {
        !isShuttingDown && !isDesktopReview && usageRestoreReadFence.accepts(ticket, generation: usageHistoryGeneration, isClearing: isClearingUsage)
    }
}
