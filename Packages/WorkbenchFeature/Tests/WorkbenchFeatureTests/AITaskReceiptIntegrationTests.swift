import Foundation
import Testing
import ExecutionCore
@testable import WorkbenchFeature

enum AIReceiptProbeMode: String, CaseIterable { case text, proposal, agent }

/// P1 durable metadata：网络前 intent、正常终态、真实子进程 SIGKILL 与重启不重放。
@Suite(.serialized) @MainActor struct AITaskReceiptIntegrationTests {
    private struct Index: Decodable { let version: Int; let receipts: [InvocationReceipt] }

    @Test func intentExistsBeforeRealHTTPAndNeverContainsContent() async throws {
        try await withStoreHTTPFixture(path: "held-text") { fixture in
            var action = fixture.action
            action.name = "synthetic-sensitive-title"; action.prompt = "synthetic-sensitive-prompt"
            let draft = fixture.store.createDraft(input: "synthetic-sensitive-input")
            let id = try #require(fixture.store.runAI(action: action, draft: draft))
            try await storeEventually { try await fixture.server.stats()["held_text_started"] == 1 }
            let file = receiptURL(fixture.directory)
            let bytes = try Data(contentsOf: file)
            let index = try JSONDecoder().decode(Index.self, from: bytes)
            #expect(index.version == 1 && index.receipts.count == 1)
            #expect(index.receipts.first?.id == id && index.receipts.first?.state == .running)
            #expect(index.receipts.first?.name == "AI action")
            let serialized = String(decoding: bytes, as: UTF8.self)
            #expect(!serialized.contains("synthetic-sensitive"))
            #expect(!serialized.contains(fixture.server.baseURL.absoluteString))
            #expect(!serialized.contains("prompt") && !serialized.contains("messages") && !serialized.contains("selectedText"))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            fixture.store.cancelTask(id)
            try await release(fixture.server)
            try await fixture.drain(id)
            let terminal = try readReceipts(fixture.directory)
            #expect(terminal.first?.state == .cancelled && terminal.first?.finishedAt != nil)
        }
    }

    @Test func failedIntentWritePreventsAnyHTTPRequest() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let folder = fixture.directory.appendingPathComponent("ai-invocations")
            let target = folder.appendingPathComponent("invocations.json")
            let backup = fixture.directory.appendingPathComponent("synthetic-ai-receipt-backup.json")
            // 目录被固定后移动目录仍可安全写入；阻断实际索引entry才是落盘失败。
            try FileManager.default.moveItem(at: target, to: backup)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let draft = fixture.store.createDraft(input: "Synthetic request that must never be sent")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.status == .failed && !task.notice.isEmpty && task.output.isEmpty)
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 0)
            #expect(try readReceiptsFrom(backup).isEmpty)
        }
    }

    @Test func cancellingBeforeTaskStartsStillProducesTerminalMetadataWithoutNetworking() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic immediate cancellation")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            fixture.store.cancelTask(id)
            try await fixture.drain(id)
            let receipts = try readReceipts(fixture.directory)
            #expect(receipts.count == 1 && receipts.first?.state == .cancelled)
            let stats = try await fixture.server.stats()
            #expect(stats["post_requests"] == 0)
        }
    }

    @Test(arguments: AIReceiptProbeMode.allCases) func normalTerminalMetadataSurvivesRelaunchWithoutReplay(_ mode: AIReceiptProbeMode) async throws {
        let route: String = switch mode { case .text: "stream"; case .proposal: "proposal"; case .agent: "agent" }
        try await withStoreHTTPFixture(path: route) { fixture in
            let store = fixture.store
            let draft = store.createDraft(input: "Synthetic terminal receipt")
            let id: UUID
            switch mode {
            case .text: id = try #require(store.runAI(action: fixture.action, draft: draft))
            case .proposal: store.generateCommandProposal(draft: draft); id = try #require(store.tasks.first?.id)
            case .agent: store.runReadOnlyAgent(draft: draft); id = try #require(store.tasks.first?.id)
            }
            try await fixture.drain(id)
            let receipts = try readReceipts(fixture.directory)
            #expect(receipts.count == 1 && receipts.first?.state == .succeeded)
            let before = try await fixture.server.stats()
            var copies = 0, reviews = 0
            let restarted = try WorkbenchModel(dataDirectory: fixture.directory, allowContextCapture: false,
                clipboardWriter: { _ in copies += 1 }, clipboardChangeCount: { 0 })
            defer { restarted.shutdown() }
            restarted.onReviewCommand = { _ in reviews += 1 }
            try await storeEventually { restarted.tasks.contains { $0.id == id && $0.restoredFromReceipt } }
            let task = try #require(restarted.tasks.first { $0.id == id })
            #expect(task.status == (mode == .proposal ? .draftReady : .completed))
            #expect(task.output.isEmpty && task.draftID == nil && task.finishedAt != nil)
            #expect(restarted.taskHandles.isEmpty && restarted.drafts.isEmpty && restarted.resultTargets.isEmpty)
            #expect(copies == 0 && reviews == 0)
            let after = try await fixture.server.stats()
            #expect(after["post_requests"] == before["post_requests"])
        }
    }

    @Test(arguments: AIReceiptProbeMode.allCases) func actualSIGKILLDuringHTTPRequestRestartsAsUnknownWithoutReplay(_ mode: AIReceiptProbeMode) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-AI-Crash-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try StoreSSEServer(); defer { server.stop() }
        let probe = try AIRecoveryProbeProcess(directory: directory, endpoint: server.endpoint("held-text"), mode: mode.rawValue)
        defer { probe.stop() }
        try await storeEventually { try await server.stats()["held_text_started"] == 1 }
        let id = probe.runID
        let pending = try readReceipts(directory)
        #expect(pending.count == 1 && pending.first?.id == id && pending.first?.state == .running)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("usage/" + id.uuidString + ".json").path))
        try probe.killForCrash()
        let serialized = String(decoding: try Data(contentsOf: receiptURL(directory)), as: UTF8.self)
        #expect(!serialized.contains("synthetic-sensitive"))
        var copies = 0, reviews = 0
        let restarted = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in copies += 1 }, clipboardChangeCount: { 0 })
        defer { restarted.shutdown() }
        restarted.onReviewCommand = { _ in reviews += 1 }
        try await storeEventually { restarted.tasks.contains { $0.id == id && $0.restoredFromReceipt } }
        let restored = try #require(restarted.tasks.first { $0.id == id })
        #expect(restored.status == .interrupted && restored.outputIsIncomplete && restored.output.isEmpty && !restored.notice.isEmpty)
        #expect(restored.finishedAt != nil && restored.draftID == nil)
        #expect(restarted.taskHandles.isEmpty && restarted.aiTaskIDs.isEmpty && restarted.drafts.isEmpty)
        #expect(restarted.resultTargets.isEmpty && restarted.latestAutoCopyRunID == nil)
        // interrupted 是终态；模拟迟到的成功也不能复活或重新派发。
        if mode == .text {
            // 保存AI动作现在是typed记录；冷启动无worker出生stamp，迟到写必须明确拒绝。
            do {
                try await restarted.aiInvocationStore.finish(id: id, result: .init(state: .succeeded, message: "synthetic-late-completion"))
                Issue.record("Unstamped completion altered a typed cold receipt")
            } catch { #expect(error as? InvocationStoreError == .staleRecovery) }
        } else {
            try await restarted.aiInvocationStore.finish(id: id, result: .init(state: .succeeded, message: "synthetic-late-completion"))
        }
        let durable = try readReceipts(directory)
        #expect(durable.first?.state == .interrupted)
        try await release(server)
        let stats = try await server.stats()
        #expect(stats["post_requests"] == 1 && copies == 0 && reviews == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("unexpected-copy").path))
    }

    @Test func terminalWriteFailureKeepsActualResultAndWarnsOfUnknownRecovery() async throws {
        try await withStoreHTTPFixture(path: "held-text") { fixture in
            let draft = fixture.store.createDraft(input: "Synthetic terminal disk failure")
            let id = try #require(fixture.store.runAI(action: fixture.action, draft: draft))
            try await storeEventually { try await fixture.server.stats()["held_text_started"] == 1 }
            let folder = fixture.directory.appendingPathComponent("ai-invocations")
            let target = folder.appendingPathComponent("invocations.json")
            let backup = fixture.directory.appendingPathComponent("synthetic-preserved-intent.json")
            try FileManager.default.moveItem(at: target, to: backup)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try await release(fixture.server)
            try await fixture.drain(id)
            let task = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(task.status == .completed && task.output == "Synthetic held result")
            #expect(!task.notice.isEmpty && !fixture.store.workspaceNotice.isEmpty)
            let preserved = try readReceiptsFrom(backup)
            #expect(preserved.first?.state == .running)
        }
    }

    private func receiptURL(_ directory: URL) -> URL { directory.appendingPathComponent("ai-invocations/invocations.json") }
    private func readReceipts(_ directory: URL) throws -> [InvocationReceipt] { try readReceiptsFrom(receiptURL(directory)) }
    private func readReceiptsFrom(_ file: URL) throws -> [InvocationReceipt] { try JSONDecoder().decode(Index.self, from: Data(contentsOf: file)).receipts }
    private func release(_ server: StoreSSEServer) async throws {
        let (_, response) = try await URLSession.shared.data(from: server.baseURL.appendingPathComponent("release-text"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
