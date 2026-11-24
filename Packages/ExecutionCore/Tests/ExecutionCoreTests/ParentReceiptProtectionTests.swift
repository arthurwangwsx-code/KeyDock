import Foundation
import Testing
@testable import ExecutionCore

@Suite(.serialized) struct ParentReceiptProtectionTests {
    @Test func cleanupFindsNewChildrenAtomicallyAndReleasesAfterParentEnds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-parent-receipt-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = try InvocationStore(directory:dir,retention:.init(maxFinishedCount:0)), parent = UUID()
        #expect(await store.list().isEmpty)
        let child = UUID()
        try await store.begin(id:child,name:"Synthetic child",commandID:"keydock.agent."+parent.uuidString)
        try await store.finish(id:child,result:.init(state:.succeeded)); await store.releaseProtection(for:child)
        #expect(await store.maintain(protectingParents:[parent]).remainingIDs == [child])
        #expect(await store.clearFinished(protectingParents:[parent]).removedIDs.isEmpty)
        #expect(await store.clearFinished().removedIDs.isEmpty)
        await store.releaseParentProtection(for:parent)
        #expect(await store.clearFinished().removedIDs == [child])
    }
    @Test func abandoningUndispatchedIntentIsTerminalAndCanBeCleared() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-abandon-receipt-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = try InvocationStore(directory:dir), id = UUID()
        try await store.begin(id:id,name:"Synthetic unlaunched")
        await store.abandonUndispatched(id)
        #expect(await store.list().first?.state == .cancelled)
        #expect(await store.clearFinished().removedIDs == [id])
    }
}
