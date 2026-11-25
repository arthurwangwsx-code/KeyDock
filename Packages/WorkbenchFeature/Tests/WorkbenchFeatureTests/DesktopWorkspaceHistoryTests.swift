import Foundation
import Testing
import ExecutionCore
import CommandCore
import MacAdapters
@testable import WorkbenchFeature

@Suite @MainActor struct DesktopWorkspaceHistoryTests {
    @Test func recoveryGroupsChildRowsUnderOneParentWithoutReplayOrCurrentDefinition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-WorkspaceHistory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkbenchModel(dataDirectory: root, allowContextCapture: false,
            clipboardWriter: { _ in Issue.record("Clipboard write") }, clipboardReader: { Issue.record("Clipboard read"); return nil },
            credentialReader: { _ in Issue.record("Credential read"); return nil }, credentialWriter: { _,_ in Issue.record("Credential write") },
            applicationCatalog: ApplicationCatalog(roots: []), applicationLauncher: { _ in Issue.record("Replay"); throw CocoaError(.featureUnsupported) }, languageApplier: { _ in })
        store.desktop.applicationCatalog.stop(); store.historyGeneration &+= 1
        let ids = [UUID(),UUID(),UUID()], parentID = UUID(), workspaceID = UUID()
        let manifest = try DesktopWorkspaceRunContext(workspaceID: workspaceID, revision: 9, entryIDs: ids)
        let parent = InvocationReceipt(id: parentID, name: "Desktop workspace", state: .interrupted, desktopWorkspaceRun: manifest)
        let context = try DesktopWorkspaceReceiptContext(parentID: parentID, entryID: ids[0], entryIndex: 0, phase: .layout)
        let child = InvocationReceipt(id: UUID(), name: "Workspace step", state: .succeeded, message: "workspace.confirmed", commandID: context.commandID, desktopWorkspace: context)
        store.restoreHistorySnapshot(cli: [child,parent], ai: [], generation: store.historyGeneration)
        #expect(store.tasks.count == 1 && store.tasks.first?.id == parentID && store.tasks.first?.desktopWorkspaceID == workspaceID)
        #expect(store.tasks.first?.desktopWorkspaceResult?.entries[0].layout == .confirmed)
        #expect(store.tasks.first?.desktopWorkspaceResult?.entries[1].layout == .unrecorded)
        #expect(store.executionReservations.isEmpty && store.taskHandles.isEmpty && store.desktopWorkspaceGroups.isEmpty && store.desktopWorkspaces.isEmpty)
        // 清理取得旧快照后，本进程已经确认完毕；重放快照只能保持当前事实。
        var known = DesktopWorkspaceRunResult(entryIDs: ids, stop: .completed)
        for index in known.entries.indices { known.entries[index].launch = .notRequired; known.entries[index].focus = .confirmed; known.entries[index].layout = .confirmed }
        store.tasks[0].desktopWorkspaceResult = known; store.tasks[0].status = .completed
        store.restoreHistorySnapshot(cli: [child,parent], ai: [], generation: store.historyGeneration)
        #expect(store.tasks.count == 1 && store.tasks[0].desktopWorkspaceResult == known && store.tasks[0].status == .completed)
        await store.shutdownAndWait()
    }
}
