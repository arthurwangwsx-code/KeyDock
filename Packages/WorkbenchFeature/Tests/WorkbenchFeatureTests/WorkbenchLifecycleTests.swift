import Foundation
import Testing
import CommandCore
import ExecutionCore
import AgentCore
import AutomationCore
import Combine
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct WorkbenchLifecycleTests {
    @Test(arguments: ["ai", "proposal", "readOnly", "agent", "workflow"], [true, false])
    func publishedTaskObserverCanCancelBeforeHandleAssignment(_ kind: String, _ quit: Bool) async throws {
        try await withStoreHTTPFixture(path: "usage") { fixture in
            let store = fixture.store
            var agent = AgentDefinition(); agent.name = "Synthetic early-published agent"
            #expect(store.saveAgent(agent)); agent = try #require(store.configuration.agents.first { $0.id == agent.id })
            let flow = WorkflowDefinition(name: "Synthetic early-published workflow", steps: [.init(operation: .aiAction(fixture.action.id))])
            #expect(store.saveWorkflow(flow))
            let saved = try #require(store.configuration.workflows.first { $0.id == flow.id })
            var intercepted = false
            let subscription = store.$tasks.sink { incoming in
                MainActor.assumeIsolated {
                    guard !intercepted, let id = incoming.first?.id,
                          store.tasks.contains(where: { $0.id == id }), store.taskHandles[id] == nil else { return }
                    intercepted = true
                    if quit { store.shutdown() } else { store.cancelTask(id) }
                }
            }
            defer { subscription.cancel() }
            let id: UUID
            switch kind {
            case "agent": id = try #require(store.runAgent(agent, input: "Synthetic early-published input"))
            case "workflow": id = try #require(store.runWorkflow(saved, input: "Synthetic early-published input"))
            default:
                let draft = store.createDraft(input: "Synthetic early-published input")
                if kind == "ai" { id = try #require(store.runAI(action: fixture.action, draft: draft)) }
                else {
                    if kind == "proposal" { store.generateCommandProposal(draft: draft) } else { store.runReadOnlyAgent(draft: draft) }
                    id = try #require(store.tasks.first?.id)
                }
            }
            try await fixture.drain(id)
            #expect(intercepted && store.tasks.first { $0.id == id }?.status == .cancelled)
            #expect(await store.aiInvocationStore.list().first { $0.id == id }?.state == .cancelled)
            #expect(try await fixture.server.stats()["post_requests"] == 0)
            #expect(store.workflowCheckpoints[id] == nil && store.pendingApprovals.isEmpty)
        }
    }
    @Test(arguments: [true, false]) func navigationCallbackCanQuitBeforeAnyAgentRequestOrCommandStarts(agent: Bool) async throws {
        try await withStoreHTTPFixture(path: "agent") { fixture in
            let store = fixture.store
            store.onOpenWorkspace = { [weak store] _ in store?.shutdown() }
            let marker = fixture.directory.appendingPathComponent("navigation-must-not-run")
            let id: UUID
            if agent {
                let draft = store.createDraft(input: "Synthetic shutdown from navigation callback")
                store.runReadOnlyAgent(draft: draft)
                id = try #require(store.tasks.first?.id)
            } else {
                id = try #require(store.runCommand(.init(name: "Synthetic blocked marker", executable: "/usr/bin/touch", arguments: [marker.path], workingDirectory: fixture.directory.path)))
            }
            try await fixture.drain(id)
            #expect(store.tasks.first { $0.id == id }?.status == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(try await fixture.server.stats()["post_requests"] == 0)
            let receipts = agent ? await store.aiInvocationStore.list() : await store.invocationStore.list()
            #expect(receipts.first { $0.id == id }?.state == .cancelled)
        }
    }

    @Test(arguments: AIReceiptProbeMode.allCases) func synchronousShutdownCancelsQueuedAIWorkBeforeItsFirstRequest(_ mode: AIReceiptProbeMode) async throws {
        let route: String = switch mode { case .text: "stream"; case .proposal: "proposal"; case .agent: "agent" }
        var copies = 0, reviews = 0
        try await withStoreHTTPFixture(path: route, clipboardWriter: { _ in copies += 1 }) { fixture in
            let store = fixture.store
            store.onReviewCommand = { _ in reviews += 1 }
            var action = fixture.action; action.output = .copy
            let draft = store.createDraft(input: "Synthetic request queued just before quitting")
            let id: UUID
            switch mode {
            case .text: id = try #require(store.runAI(action: action, draft: draft))
            case .proposal: store.generateCommandProposal(draft: draft); id = try #require(store.tasks.first?.id)
            case .agent: store.runReadOnlyAgent(draft: draft); id = try #require(store.tasks.first?.id)
            }
            store.shutdown()
            try await fixture.drain(id)
            #expect(store.tasks.first { $0.id == id }?.status == .cancelled)
            #expect(copies == 0 && reviews == 0)
            #expect(try await fixture.server.stats()["post_requests"] == 0)
            #expect(await store.aiInvocationStore.list().first { $0.id == id }?.state == .cancelled)
        }
    }

    @Test func shutdownRejectsNewWorkWithoutNetworkProcessesOrNavigation() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store
            var navigation = 0
            store.onOpenWorkspace = { _ in navigation += 1 }
            store.onOpenSettings = { _ in navigation += 1 }
            await store.shutdownAndWait()
            let draft = store.createDraft(input: "Synthetic queued after shutdown")
            #expect(store.runAI(action: fixture.action, draft: draft) == nil)
            store.generateCommandProposal(draft: draft)
            store.runReadOnlyAgent(draft: draft)
            store.runCommand(.init(name: "Synthetic stopped command", executable: "/usr/bin/printf", arguments: ["must not run"]))
            store.execute(.init(id: "utility.settings", title: "Synthetic Settings", kind: .utility, payload: "settings"))
            #expect(store.isShuttingDown && store.tasks.isEmpty && store.taskHandles.isEmpty)
            #expect(store.configuration.preferences.recent.isEmpty && navigation == 0)
            #expect(!draft.notice.isEmpty)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func copyingAnEmptyTaskResultDoesNotClearTheClipboard() async throws {
        var writes: [String] = []
        try await withStoreHTTPFixture(path: "stream", clipboardWriter: { writes.append($0) }) { fixture in
            let id = UUID()
            fixture.store.tasks = [.init(id: id, title: "Synthetic empty result", state: .completed, finishedAt: Date())]
            fixture.store.copyResult(id)
            #expect(writes.isEmpty)
            #expect(!fixture.store.tasks[0].notice.isEmpty)
        }
    }
}
