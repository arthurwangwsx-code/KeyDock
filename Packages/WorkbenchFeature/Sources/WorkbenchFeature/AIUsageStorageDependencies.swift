import Foundation
import Darwin
import ExecutionCore

/// 构造期注入；生产始终连接真实Core，不在启动后替换账本。
struct AIUsageStorageDependencies: Sendable {
    var policy = AIUsageRetentionPolicy()
    var clock: @Sendable () -> Date = { Date() }
    var dailyInterval: Duration = .seconds(86_400)
    var removeEntry: AIUsageMetadataStore.RemoveEntry = { descriptor, name in
        guard unlinkat(descriptor, name, 0) == 0 else { throw POSIXError(.EIO) }
    }
    var syncDirectory: AIUsageMetadataStore.SyncDirectory = { descriptor in
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
    var beforePrepare: @Sendable (Set<UUID>, Bool) async -> Void = { _, _ in }
    var beforeReport: @Sendable (AIUsageMaintenanceReport) async -> Void = { _ in }
    var beforeFinalInventory: @Sendable (AIUsageMaintenanceTrigger) throws -> Void = { _ in }

    func makeStore(directory: URL, budgetStore: InvocationStore) -> AIUsageMetadataStore {
        AIUsageMetadataStore(directory: directory, policy: policy, clock: clock, dailyInterval: dailyInterval,
            removeEntry: removeEntry, prepareRemoval: { ids, all, tickets in
                await beforePrepare(ids, all)
                return try await budgetStore.prepareUsageRemoval(for: ids, clearingAllRecorded: all, retrying: tickets)
            }, beforeFinalInventory: beforeFinalInventory, syncDirectory: syncDirectory)
    }
}
