import Foundation
import Testing
import MacAdapters
import ExecutionCore
@testable import WorkbenchFeature

enum WorkflowIntegrationFixtureError: Error { case timedOut, unexpectedCapability }

/// 每个测试只拥有一个随机临时目录；所有正文、参数和潜在marker均为合成数据。
@MainActor final class WorkflowIntegrationFixture {
    let directory: URL
    let store: WorkbenchModel

    init(configurationWriter: (@MainActor (Data, URL) throws -> Void)? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Workflow-Integration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var configuration = AppConfiguration()
            configuration.aiActions = []; configuration.clipboardEnabled = false
            try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"), options: .withoutOverwriting)
            store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
                clipboardWriter: { _ in Issue.record("Unexpected synthetic clipboard write") },
                clipboardChangeCount: { 0 }, clipboardReader: { Issue.record("Unexpected clipboard input"); return nil },
                credentialReader: { _ in Issue.record("Unexpected credential read"); throw WorkflowIntegrationFixtureError.unexpectedCapability },
                credentialWriter: { _,_ in Issue.record("Unexpected credential write"); throw WorkflowIntegrationFixtureError.unexpectedCapability },
                configurationWriter: configurationWriter ?? { try PrivateFiles.write($0, to: $1) },
                applicationCatalog: ApplicationCatalog(roots: []),
                applicationLauncher: { _ in throw WorkflowIntegrationFixtureError.unexpectedCapability },
                clipboardCaptureSource: WorkflowIntegrationClipboardSource(), languageApplier: { _ in })
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func stopAutomaticWork() async {
        store.monitor.stop(); store.desktop.applicationCatalog.stop()
        let timer = store.scheduleTimer
        timer?.cancel(); await timer?.value; store.scheduleTimer = nil
        store.receiptMaintenanceTask?.cancel(); store.receiptMaintenanceTask = nil
    }
    func cleanup() async {
        await store.shutdownAndWait()
        try? FileManager.default.removeItem(at: directory)
    }
    func eventually(_ predicate: @MainActor () async throws -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        throw WorkflowIntegrationFixtureError.timedOut
    }
    func drain(_ id: UUID) async throws {
        try await eventually { self.store.taskHandles[id] == nil && !self.store.executionReservations.contains(id) }
    }
    func task(_ id: UUID) throws -> RunningTaskItem { try #require(store.tasks.first { $0.id == id }) }
    func childReceipts(_ runID: UUID) async -> [InvocationReceipt] {
        await store.agentToolStore.list().filter { $0.commandID == "keydock.workflow-run." + runID.uuidString }
    }
    func assertNoExecution(markers: [URL] = []) async {
        #expect(store.tasks.isEmpty && store.taskHandles.isEmpty && store.executionReservations.isEmpty)
        #expect(store.pendingApprovals.isEmpty && store.scheduledRuns.isEmpty)
        let parents = await store.aiInvocationStore.list(), children = await store.agentToolStore.list()
        #expect(parents.isEmpty && children.isEmpty)
        for marker in markers { #expect(!FileManager.default.fileExists(atPath: marker.path)) }
    }
}

@MainActor func withWorkflowIntegrationFixture(_ body: @MainActor (WorkflowIntegrationFixture) async throws -> Void) async throws {
    let fixture = try WorkflowIntegrationFixture()
    await fixture.stopAutomaticWork()
    do { try await body(fixture); await fixture.cleanup() }
    catch { await fixture.cleanup(); throw error }
}

/// monitor初始化也不能触碰系统pasteboard；这里只返回固定的合成元数据。
@MainActor private final class WorkflowIntegrationClipboardSource: ClipboardCaptureSource {
    var changeCount: Int { 0 }
    var availableTypes: [String] { [] }
    var sourceApplication: String? { nil }
    func readText() -> String? { Issue.record("Unexpected capture of clipboard text"); return nil }
}
