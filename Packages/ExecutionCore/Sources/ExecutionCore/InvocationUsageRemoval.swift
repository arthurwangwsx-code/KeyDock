import Foundation

/// 仅在同一Store出生实例内有效；避免延后清理误绑后来复用的UUID。
public struct InvocationUsageClearTicket: Sendable, Equatable {
    public let invocationID: UUID
    let storeIdentity: UUID
    let birth: UUID
}

/// 只确认用量副本的删除前置；不是回执删除或执行授权。
public struct InvocationUsageRemoval: Sendable {
    public let approvedIDs: Set<UUID>
    public let budgetRedactedIDs: Set<UUID>
    public let deferredIDs: Set<UUID>
    public let deferredBudgets: [InvocationUsageClearTicket]
    public init(approvedIDs: Set<UUID>, budgetRedactedIDs: Set<UUID> = [], deferredIDs: Set<UUID> = [], deferredBudgets: [InvocationUsageClearTicket] = []) {
        self.approvedIDs = approvedIDs; self.budgetRedactedIDs = budgetRedactedIDs; self.deferredIDs = deferredIDs
        self.deferredBudgets = deferredBudgets
    }
}
