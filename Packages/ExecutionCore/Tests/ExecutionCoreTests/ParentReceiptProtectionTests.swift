import Foundation
import Testing
@testable import ExecutionCore

@Suite(.serialized) struct ParentReceiptProtectionTests {
    @Test(arguments: ["keydock.agent.","keydock.workflow-run.",DesktopWorkspaceReceiptContext.commandPrefix])
    func cleanupFindsNewChildrenAtomicallyAndReleasesAfterParentEnds(prefix: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-parent-receipt-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = try InvocationStore(directory:dir,retention:.init(maxFinishedCount:0)), parent = UUID()
        #expect(await store.list().isEmpty)
        let child = UUID()
        let context = prefix == DesktopWorkspaceReceiptContext.commandPrefix ? try DesktopWorkspaceReceiptContext(parentID: parent, entryID: UUID(), entryIndex: 0, phase: .layout) : nil
        if let context {
            let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: [context.entryID])
            try await store.begin(id: parent, name: "Synthetic workspace", desktopWorkspaceRun: manifest)
        }
        let expected: Set<UUID> = context == nil ? [child] : [parent,child]
        try await store.begin(id:child,name:"Synthetic child",commandID:prefix+parent.uuidString,desktopWorkspace:context)
        try await store.finish(id:child,result:.init(state:.succeeded)); await store.releaseProtection(for:child)
        #expect(await store.maintain(protectingParents:[parent]).remainingIDs == expected)
        #expect(await store.clearFinished(protectingParents:[parent]).removedIDs.isEmpty)
        #expect(await store.clearFinished().removedIDs.isEmpty)
        if context != nil { try await store.finish(id: parent, result: .init(state: .succeeded)); await store.releaseProtection(for: parent) }
        await store.releaseParentProtection(for:parent)
        #expect(await store.clearFinished().removedIDs == expected)
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
