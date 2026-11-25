import Foundation
import Testing
@testable import ExecutionCore

/// 只使用独占临时档案；恢复只读事实，不连接任何原生执行端口。
@Suite(.serialized) struct DesktopWorkspaceReceiptTests {
    private struct Archive: Codable { let version: Int; let receipts: [InvocationReceipt] }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-WorkspaceReceipt-" + UUID().uuidString) }
    private func context(_ parent: UUID, index: Int = 0, phase: DesktopWorkspaceReceiptPhase = .layout) throws -> DesktopWorkspaceReceiptContext {
        try .init(parentID: parent, entryID: UUID(), entryIndex: index, phase: phase)
    }

    @Test func liveParentProtectsNewFinishedChildrenUntilAllAreReleased() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try InvocationStore(directory: dir, retention: .init(maxFinishedCount: 0)), parent = UUID()
        let first = try context(parent), second = try context(parent, index: 1), a = UUID(), b = UUID()
        let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: [first.entryID,second.entryID])
        try await store.begin(id: parent, name: "Synthetic", desktopWorkspaceRun: manifest)
        try await store.begin(id: a, name: "Synthetic", commandID: first.commandID, desktopWorkspace: first)
        try await store.finish(id: a, result: .init(state: .succeeded, message: "workspace.confirmed")); await store.releaseProtection(for: a)
        let staleSnapshot: Set<UUID> = []
        try await store.begin(id: b, name: "Synthetic", commandID: second.commandID, desktopWorkspace: second)
        try await store.finish(id: b, result: .init(state: .interrupted, message: "workspace.unknown")); await store.releaseProtection(for: b)
        #expect(await store.clearFinished(excluding: staleSnapshot).removedIDs.isEmpty)
        #expect(await store.maintain().remainingIDs == [parent,a,b])
        try await store.finish(id: parent, result: .init(state: .interrupted)); await store.releaseProtection(for: parent)
        await store.releaseParentProtection(for: parent)
        #expect(await store.clearFinished().removedIDs == [parent,a,b])
    }

    @Test func recoveryKeepsUnknownParentAndConfirmedChildBeforePruning() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let parent = UUID(), child = UUID(), metadata = try context(parent, index: 2, phase: .focus)
        let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 3, entryIDs: [UUID(),UUID(),metadata.entryID])
        do {
            let store = try InvocationStore(directory: dir, retention: .init(maxFinishedCount: 0))
            try await store.begin(id: parent, name: "Synthetic workspace", commandID: "desktop-workspace." + UUID().uuidString, desktopWorkspaceRun: manifest)
            try await store.begin(id: child, name: "Synthetic focus", commandID: metadata.commandID, initialMessage: "workspace.intent", desktopWorkspace: metadata)
            try await store.finish(id: child, result: .init(state: .succeeded, message: "workspace.confirmed"))
            await store.releaseProtection(for: child)
        }
        let restored = try InvocationStore(directory: dir, retention: .init(maxFinishedCount: 0))
        let values = await restored.list()
        #expect(Set(values.map(\.id)) == [parent,child])
        #expect(values.first(where: { $0.id == parent })?.state == .interrupted)
        #expect(values.first(where: { $0.id == parent })?.desktopWorkspaceRun == manifest)
        #expect(values.first(where: { $0.id == child })?.state == .succeeded)
        #expect(values.first(where: { $0.id == child })?.desktopWorkspace == metadata)
        #expect(await restored.maintain().removedIDs.isEmpty)
        await restored.acknowledgeRecovery()
        #expect(await restored.maintain().removedIDs == [parent,child])
    }

    @Test func recoveredChildWithFinishedParentKeepsSiblingFacts() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let parent = UUID(), finished = UUID(), unfinished = UUID(), a = try context(parent), b = try context(parent, index: 1, phase: .launch)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: [a.entryID,b.entryID])
        let old = [InvocationReceipt(id: parent, name: "Synthetic parent", state: .succeeded, desktopWorkspaceRun: manifest),
                   InvocationReceipt(id: finished, name: "Synthetic child", state: .succeeded, commandID: a.commandID, desktopWorkspace: a),
                   InvocationReceipt(id: unfinished, name: "Synthetic child", state: .running, commandID: b.commandID, desktopWorkspace: b)]
        try JSONEncoder().encode(Archive(version: 1, receipts: old)).write(to: dir.appendingPathComponent("invocations.json"))
        let restored = try InvocationStore(directory: dir, retention: .init(maxFinishedCount: 0))
        #expect(Set(await restored.list().map(\.id)) == [parent,finished,unfinished])
        let recovered = try #require(await restored.list().first(where: { $0.id == unfinished }))
        #expect(recovered.state == .interrupted && recovered.message == "process.interrupted.unknown" && recovered.desktopWorkspace == b)
        #expect(await restored.clearFinished().removedIDs.isEmpty)
    }

    @Test func contextIsMinimalBoundedAndSurvivesMessageReplacement() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let parent = UUID(), id = UUID(), metadata = try context(parent, index: 7, phase: .launch)
        let store = try InvocationStore(directory: dir)
        let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: (0..<7).map { _ in UUID() } + [metadata.entryID])
        try await store.begin(id: parent, name: "Synthetic", desktopWorkspaceRun: manifest)
        try await store.begin(id: id, name: "Synthetic", commandID: metadata.commandID, desktopWorkspace: metadata)
        let raw = try Data(contentsOf: dir.appendingPathComponent("invocations.json"))
        let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let row = try #require((json["receipts"] as? [[String: Any]])?.first(where: { $0["desktopWorkspace"] != nil }))
        let body = try #require(row["desktopWorkspace"] as? [String: Any])
        #expect(Set(body.keys) == ["parentID","entryID","entryIndex","phase"])
        let restored = try InvocationStore(directory: dir)
        #expect(await restored.list().first?.desktopWorkspace == metadata)
        #expect(await restored.list().first?.message == "process.interrupted.unknown")
        for index in [-1,8,Int.max] { #expect(throws: InvocationStoreError.invalidMetadata) { try DesktopWorkspaceReceiptContext(parentID: parent, entryID: UUID(), entryIndex: index, phase: .layout) } }
    }

    @Test func invalidRelationshipAndMalformedReservedPrefixCannotEnterArchive() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try InvocationStore(directory: dir), parent = UUID(), metadata = try context(parent)
        let original = try Data(contentsOf: dir.appendingPathComponent("invocations.json"))
        for id in [metadata.commandID + ".step", DesktopWorkspaceReceiptContext.commandPrefix + "short", metadata.commandID] {
            await #expect(throws: InvocationStoreError.invalidMetadata) { try await store.begin(id: UUID(), name: "Synthetic", commandID: id) }
        }
        await #expect(throws: InvocationStoreError.invalidMetadata) { try await store.begin(id: UUID(), name: "Synthetic", commandID: "keydock.agent." + parent.uuidString, desktopWorkspace: metadata) }
        await #expect(throws: InvocationStoreError.invalidMetadata) { try await store.begin(id: parent, name: "Synthetic", commandID: metadata.commandID, desktopWorkspace: metadata) }
        #expect(try Data(contentsOf: dir.appendingPathComponent("invocations.json")) == original)
    }

    @Test func invalidContextOnLoadPreservesOriginalBytesAndOldArchiveStillLoads() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let parent = UUID(), metadata = try context(parent)
        let valid = InvocationReceipt(id: UUID(), name: "Synthetic", state: .succeeded, commandID: metadata.commandID, desktopWorkspace: metadata)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Archive(version: 1, receipts: [valid]))) as? [String: Any])
        var rows = try #require(json["receipts"] as? [[String: Any]]), body = try #require(rows[0]["desktopWorkspace"] as? [String: Any])
        body["entryIndex"] = 8; rows[0]["desktopWorkspace"] = body; json["receipts"] = rows
        let invalid = try JSONSerialization.data(withJSONObject: json)
        let file = dir.appendingPathComponent("invocations.json"); try invalid.write(to: file)
        #expect(throws: InvocationStoreError.invalidMetadata) { try InvocationStore(directory: dir) }
        #expect(try Data(contentsOf: file) == invalid)
        let old = InvocationReceipt(id: UUID(), name: "Synthetic old", state: .succeeded)
        try JSONEncoder().encode(Archive(version: 1, receipts: [old])).write(to: file)
        let store = try InvocationStore(directory: dir)
        #expect(await store.list() == [old])
    }

    @Test func parentManifestIsBoundedAndRejectsMismatchedChildOrder() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try InvocationStore(directory: dir), parent = UUID(), entry = UUID()
        let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: [entry])
        try await store.begin(id: parent, name: "Synthetic", desktopWorkspaceRun: manifest)
        let original = try Data(contentsOf: dir.appendingPathComponent("invocations.json"))
        for c in [try context(parent), try DesktopWorkspaceReceiptContext(parentID: parent, entryID: entry, entryIndex: 1, phase: .focus)] {
            await #expect(throws: InvocationStoreError.invalidMetadata) { try await store.begin(id: UUID(), name: "Synthetic", commandID: c.commandID, desktopWorkspace: c) }
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("invocations.json")) == original)
        let valid = try DesktopWorkspaceReceiptContext(parentID: parent, entryID: entry, entryIndex: 0, phase: .focus)
        try await store.begin(id: UUID(), name: "Synthetic", commandID: valid.commandID, desktopWorkspace: valid)
        #expect(throws: InvocationStoreError.invalidMetadata) { try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 0, entryIDs: [entry]) }
        for ids in [[], [entry,entry], (0..<9).map { _ in UUID() }] {
            #expect(throws: InvocationStoreError.invalidMetadata) { try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: ids) }
        }
    }

    @Test func mismatchedArchivedChildCannotReinterpretTheParentManifest() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let parent = UUID(), manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: [UUID()]), c = try context(parent)
        let receipts = [InvocationReceipt(id: parent, name: "Synthetic", state: .running, desktopWorkspaceRun: manifest),
                        InvocationReceipt(id: UUID(), name: "Synthetic", state: .succeeded, commandID: c.commandID, desktopWorkspace: c)]
        let raw = try JSONEncoder().encode(Archive(version: 1, receipts: receipts)), file = dir.appendingPathComponent("invocations.json")
        try raw.write(to: file)
        #expect(throws: InvocationStoreError.invalidMetadata) { try InvocationStore(directory: dir) }
        #expect(try Data(contentsOf: file) == raw)
    }

    @Test(arguments: ["missing", "ordinary", "terminal"])
    func newChildRequiresAnActiveWorkspaceParent(kind: String) async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try InvocationStore(directory: dir), parent = UUID(), c = try context(parent)
        if kind == "ordinary" { try await store.begin(id: parent, name: "Synthetic CLI") }
        if kind == "terminal" {
            let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: [c.entryID])
            try await store.begin(id: parent, name: "Synthetic workspace", desktopWorkspaceRun: manifest)
            try await store.finish(id: parent, result: .init(state: .succeeded))
        }
        let file = dir.appendingPathComponent("invocations.json"), before = try Data(contentsOf: file)
        await #expect(throws: InvocationStoreError.invalidMetadata) { try await store.begin(id: UUID(), name: "Synthetic", commandID: c.commandID, desktopWorkspace: c) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func archivedOrdinaryParentIsRejectedButOrphanFactsRemainReadable() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let parent = UUID(), c = try context(parent), child = InvocationReceipt(id: UUID(), name: "Synthetic", state: .succeeded, commandID: c.commandID, desktopWorkspace: c)
        let old = InvocationReceipt(id: parent, name: "Synthetic CLI", state: .succeeded)
        let file = dir.appendingPathComponent("invocations.json"), invalid = try JSONEncoder().encode(Archive(version: 1, receipts: [old,child]))
        try invalid.write(to: file)
        #expect(throws: InvocationStoreError.invalidMetadata) { try InvocationStore(directory: dir) }
        #expect(try Data(contentsOf: file) == invalid)
        try JSONEncoder().encode(Archive(version: 1, receipts: [child])).write(to: file)
        let restored = try InvocationStore(directory: dir)
        #expect(await restored.list() == [child])
    }
}
