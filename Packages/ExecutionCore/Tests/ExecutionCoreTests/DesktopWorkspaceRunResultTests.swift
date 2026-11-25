import Foundation
import Testing
@testable import ExecutionCore

@Suite struct DesktopWorkspaceRunResultTests {
    @Test func parentSummarySurvivesChildPruningAndRestartWithoutMutableDefinitions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-WorkspaceResult-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InvocationStore(directory: root), parent = UUID(), entries = [UUID(),UUID(),UUID()]
        let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 4, entryIDs: entries)
        try await store.begin(id: parent, name: "Desktop workspace", desktopWorkspaceRun: manifest)
        var report = DesktopWorkspaceRunResult(entryIDs: entries)
        report.entries[0].launch = .notRequired; report.entries[0].focus = .confirmed; report.entries[0].layout = .confirmed
        report.entries[1].launch = .confirmed; report.entries[1].focus = .unknown
        try await store.finish(id: parent, result: .init(state: report.state), desktopWorkspaceResult: report)
        let restored = try InvocationStore(directory: root), receipt = try #require(await restored.list().first)
        #expect(receipt.desktopWorkspaceResult == report && receipt.desktopWorkspaceRun == manifest)
        #expect(DesktopWorkspaceRunResult.recover(parent: receipt, children: []) == report)
        let bytes = try String(contentsOf: root.appendingPathComponent("invocations.json"), encoding: .utf8)
        #expect(!bytes.contains("pid") && !bytes.contains("applicationID") && !bytes.contains("frame"))
    }
    @Test func interruptedManifestWithoutChildNeverInventsNotExecuted() {
        let ids = [UUID(),UUID()], manifest = try! DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 7, entryIDs: ids)
        let parent = InvocationReceipt(id: UUID(), name: "Desktop workspace", state: .interrupted, desktopWorkspaceRun: manifest)
        let report = DesktopWorkspaceRunResult.recover(parent: parent, children: [])
        #expect(report?.state == .interrupted && report?.entries.map(\.launch) == [.unrecorded,.unrecorded])
        #expect(report?.entries.allSatisfy { $0.layout == .unrecorded && $0.focus == .unrecorded } == true)
    }
    @Test func knownChildrenRestoreInManifestOrderAndDuplicatePhasesStayUnknown() throws {
        let ids = [UUID(),UUID()], parent = UUID(), manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: ids)
        let receipt = InvocationReceipt(id: parent, name: "Desktop workspace", state: .interrupted, desktopWorkspaceRun: manifest)
        let context = try DesktopWorkspaceReceiptContext(parentID: parent, entryID: ids[1], entryIndex: 1, phase: .layout)
        let child = InvocationReceipt(id: UUID(), name: "Workspace step", state: .succeeded, message: "workspace.confirmed", commandID: context.commandID, desktopWorkspace: context)
        let report = try #require(DesktopWorkspaceRunResult.recover(parent: receipt, children: [child]))
        #expect(report.entries.map(\.entryID) == ids && report.entries[1].layout == .confirmed && report.entries[0].layout == .unrecorded)
        var duplicate = child; duplicate.message = "workspace.unknown"; duplicate.state = .interrupted
        #expect(DesktopWorkspaceRunResult.recover(parent: receipt, children: [child,duplicate])?.entries[1].layout == .unknown)
    }
    @Test(arguments: ["ordinary","order","state","phase"])
    func invalidParentSummaryIsRejectedWithoutChangingBytes(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-WorkspaceInvalidResult-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InvocationStore(directory: root), parent = UUID(), ids = [UUID(),UUID()]
        let manifest = try DesktopWorkspaceRunContext(workspaceID: UUID(), revision: 1, entryIDs: ids)
        try await store.begin(id: parent, name: "Synthetic", desktopWorkspaceRun: kind == "ordinary" ? nil : manifest)
        let file = root.appendingPathComponent("invocations.json"), before = try Data(contentsOf: file)
        var report = DesktopWorkspaceRunResult(entryIDs: kind == "order" ? Array(ids.reversed()) : ids)
        if kind == "phase" { report.entries[0].layout = .notRequired }
        await #expect(throws: InvocationStoreError.invalidMetadata) { try await store.finish(id: parent, result: .init(state: kind == "state" ? .succeeded : report.state), desktopWorkspaceResult: report) }
        #expect(try Data(contentsOf: file) == before)
    }
    @Test func allEightEntryResultsFitReservedCompletionSpace() throws {
        var report = DesktopWorkspaceRunResult(entryIDs: (0..<8).map { _ in UUID() }, stop: .completed)
        for i in report.entries.indices { report.entries[i].launch = .confirmed; report.entries[i].focus = .confirmed; report.entries[i].layout = .confirmed }
        #expect(try JSONEncoder().encode(report).count < 4_096)
        #expect(report.state == .succeeded)
        report.receiptUncertain = true; #expect(report.state == .interrupted && report.entries.allSatisfy { $0.layout == .confirmed })
    }
}
