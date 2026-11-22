import Foundation
import Testing
import ExecutionCore
import MacAdapters
@testable import WorkbenchFeature

/// 所有打开请求都由合成 adapter 接管；不访问 Terminal、Shell、Keychain 或个人剪贴板。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct TerminalLifecycleTests {
    private func withStore(
        adapter: TerminalHandoffAdapter,
        _ operation: (WorkbenchModel, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Terminal-Synthetic-" + UUID().uuidString)
        let languageKey = (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) ? "KeyDock.Smoke.Language" : "KeyDock.Language"
        let language = UserDefaults.standard.object(forKey: languageKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil }, terminalHandoff: adapter)
        do {
            try await storeEventually { !store.catalog.isEmpty }
            try await operation(store, directory)
        } catch {
            await store.shutdownAndWait()
            if let language { UserDefaults.standard.set(language, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await store.shutdownAndWait()
        if let language { UserDefaults.standard.set(language, forKey: languageKey) }
        else { UserDefaults.standard.removeObject(forKey: languageKey) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func command() -> SavedCommand {
        SavedCommand(name: "Synthetic terminal request", executable: "/usr/bin/true", interactive: true)
    }

    @Test func queuedTerminalWorkIsCancelledBeforeAnySubmissionOnQuit() async throws {
        var opens = 0
        let adapter = TerminalHandoffAdapter { _, _ in opens += 1 }
        try await withStore(adapter: adapter) { store, directory in
            store.runCommand(command(), showWorkspace: false)
            let id = try #require(store.tasks.first?.id)
            await store.shutdownAndWait()
            #expect(opens == 0 && store.taskHandles.isEmpty)
            #expect(store.tasks.first { $0.id == id }?.status == .cancelled)
            #expect(await store.invocationStore.list().first { $0.id == id }?.state == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("terminal-launches").path))
        }
    }

    @Test func pendingHandoffIsNotCancellableAndQuitPersistsUnknownBeforeLateAck() async throws {
        var reply: (@Sendable (Bool) -> Void)?, submittedFile: URL?
        let adapter = TerminalHandoffAdapter(acknowledgementTimeout: .milliseconds(250)) { file, completion in
            submittedFile = file; reply = completion
        }
        try await withStore(adapter: adapter) { store, _ in
            store.runCommand(command(), showWorkspace: false)
            let id = try #require(store.tasks.first?.id)
            try await storeEventually { submittedFile != nil }
            #expect(store.tasks.first { $0.id == id }?.status == .handoffPending)
            #expect(store.tasks.first { $0.id == id }?.canCancel == false)
            store.cancelTask(id)
            #expect(!store.cancelledTaskIDs.contains(id))
            let started = ContinuousClock.now
            await store.shutdownAndWait()
            #expect(started.duration(to: .now) < .seconds(2))
            #expect(store.tasks.first { $0.id == id }?.status == .interrupted)
            let receipt = try #require(await store.invocationStore.list().first { $0.id == id })
            #expect(receipt.state == .interrupted && receipt.message == "terminal.handoffUnknown")
            #expect(FileManager.default.fileExists(atPath: try #require(submittedFile).path))
            reply?(true); reply?(false)
            await Task.yield()
            #expect(store.tasks.first { $0.id == id }?.status == .interrupted)
            #expect(await store.invocationStore.list().first { $0.id == id }?.message == "terminal.handoffUnknown")
        }
    }

    @Test func acknowledgedHandoffSurvivesQuitWithoutClaimingCommandCompletion() async throws {
        let adapter = TerminalHandoffAdapter { _, reply in reply(true) }
        try await withStore(adapter: adapter) { store, _ in
            store.runCommand(command(), showWorkspace: false)
            let id = try #require(store.tasks.first?.id)
            try await storeEventually { store.taskHandles[id] == nil }
            await store.shutdownAndWait()
            #expect(store.tasks.first { $0.id == id }?.status == .handedOff)
            let receipt = try #require(await store.invocationStore.list().first { $0.id == id })
            #expect(receipt.message == "terminal.handedOff" && receipt.exitCode == nil)
            // 启动恢复的快照可能晚于新任务到达，不能插入同 ID 的第二条任务。
            store.restoreReceipt(receipt)
            #expect(store.tasks.filter { $0.id == id }.count == 1)
            #expect(!store.cancelledTaskIDs.contains(id))
        }
    }

    @Test func rejectedHandoffRecordsFailureAndRemovesUnacceptedScript() async throws {
        var file: URL?
        let adapter = TerminalHandoffAdapter { value, reply in file = value; reply(false) }
        try await withStore(adapter: adapter) { store, _ in
            store.runCommand(command(), showWorkspace: false)
            let id = try #require(store.tasks.first?.id)
            try await storeEventually { store.taskHandles[id] == nil }
            #expect(store.tasks.first { $0.id == id }?.status == .failed)
            #expect(await store.invocationStore.list().first { $0.id == id }?.message == "terminal.handoffFailed")
            #expect(!FileManager.default.fileExists(atPath: try #require(file).path))
        }
    }
}
