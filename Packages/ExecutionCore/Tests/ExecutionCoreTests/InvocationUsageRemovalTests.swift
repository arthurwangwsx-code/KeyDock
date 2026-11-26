import Foundation
import Testing
@testable import ExecutionCore

@Suite struct InvocationUsageRemovalTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Synthetic-UsageRemoval-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func seed(_ store: InvocationStore, id: UUID = UUID(), tokens: Int = 31, release: Bool) async throws -> UUID {
        try await store.begin(id: id, name: "Synthetic usage budget", runTokenBudget: .init(maximumTokens: 100))
        try await store.finish(id: id, result: .init(state: .succeeded), runTokenBudget: .init(maximumTokens: 100, knownTokens: tokens, completedTurns: 2, status: .verified))
        if release { await store.releaseProtection(for: id) }
        return id
    }
    @Test func terminalOrphanIsDeferredUntilOwnerReleaseWithoutClearingLaterRun() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try InvocationStore(directory: root), first = try await seed(store, release: false)
        let initial = try await store.prepareUsageRemoval(for: [], clearingAllRecorded: true)
        #expect(initial.deferredIDs == [first] && initial.deferredBudgets.count == 1 && initial.budgetRedactedIDs.isEmpty)
        let later = try await seed(store, tokens: 44, release: true)
        await store.releaseProtection(for: first)
        let retried = try await store.prepareUsageRemoval(for: [], retrying: initial.deferredBudgets)
        #expect(retried.deferredIDs.isEmpty && retried.budgetRedactedIDs == [first])
        let rows = await store.list()
        #expect(rows.first { $0.id == first }?.runTokenBudget?.knownTokens == nil)
        #expect(rows.first { $0.id == later }?.runTokenBudget?.knownTokens == 44)
    }
    @Test func deferredTicketDoesNotBindReusedLegacyUUIDOrAnotherStore() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try InvocationStore(directory: root), id = try await seed(store, release: false)
        let old = try await store.prepareUsageRemoval(for: [], clearingAllRecorded: true)
        await store.releaseProtection(for: id)
        let cleanup = await store.clearFinished(onlyIDs: [id])
        #expect(cleanup.removedIDs == [id])
        _ = try await seed(store, id: id, tokens: 44, release: true)
        let stale = try await store.prepareUsageRemoval(for: [], retrying: old.deferredBudgets)
        #expect(stale.budgetRedactedIDs.isEmpty)
        #expect(await store.list().first?.runTokenBudget?.knownTokens == 44)
        let otherRoot = try directory(); defer { try? FileManager.default.removeItem(at: otherRoot) }
        let other = try InvocationStore(directory: otherRoot)
        _ = try await seed(other, id: id, tokens: 55, release: true)
        let foreign = try await other.prepareUsageRemoval(for: [], retrying: old.deferredBudgets)
        #expect(foreign.budgetRedactedIDs.isEmpty)
        #expect(await other.list().first?.runTokenBudget?.knownTokens == 55)
    }
}
