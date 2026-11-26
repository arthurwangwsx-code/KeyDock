import Foundation
import Darwin
import Testing
import ExecutionCore
import AutomationCore
import AgentCore
import CommandCore
import AICore
import MCPAdapters
@testable import WorkbenchFeature

private final class AttemptTestIO: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var failure: InvocationPersistencePoint?
    private var domain = "cli"
    private var held = false
    private var waiting = false
    func fail(_ point: InvocationPersistencePoint?) { lock.withLock { failure = point } }
    func hold(_ domain: String = "cli") { lock.withLock { self.domain = domain; held = true; waiting = false } }
    var entered: Bool { lock.withLock { waiting } }
    func release() { lock.withLock { held = false }; signal.signal() }
    func code(_ domain: String, _ point: InvocationPersistencePoint) -> Int32? {
        let state = lock.withLock { () -> (Bool, Int32?) in
            guard domain == self.domain else { return (false, nil) }
            let pause = held && point == .beforeWrite
            if pause { waiting = true }
            return (pause, failure == point ? EIO : nil)
        }
        if state.0, signal.wait(timeout: .now() + 5) == .timedOut { return ETIMEDOUT }
        return state.1
    }
}

@MainActor private func withAttemptFixture(_ body: @MainActor (WorkflowIntegrationFixture, AttemptTestIO) async throws -> Void) async throws {
    let io = AttemptTestIO()
    let f = try WorkflowIntegrationFixture(invocationPersistenceFault: { io.code($0, $1) })
    await f.stopAutomaticWork()
    do { try await body(f, io); io.release(); await f.cleanup() }
    catch { io.release(); await f.cleanup(); throw error }
}

@MainActor private func seedAttempt(_ f: WorkflowIntegrationFixture, definition: SavedRunDefinition,
                                   state: ExecutionState = .succeeded, message: String = "synthetic.priorResult") async throws -> AttemptOrigin {
    let reference = try definition.reference
    let kind: AttemptReceiptStore = reference.kind == .savedCommand ? .cli : .ai
    let store = f.store.receiptStore(kind), id = UUID()
    let name: String
    switch reference.kind { case .savedCommand: name = "Synthetic prior CLI"; case .aiAction: name = "AI action"; case .agent: name = "Agent run"; case .workflow: name = "Workflow run" }
    let begun = try await store.begin(id: id, name: name, runDefinition: reference)
    try await store.finish(id: id, result: .init(state: state, exitCode: state == .succeeded ? 0 : nil, message: message), expectedRunStamp: begun.runStamp)
    await store.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
    let row = try #require(await store.list().first { $0.id == id })
    // 构造冷启动投影；初始异步恢复可能已见到夹具在begin/finish之间的临时running快照。
    f.store.tasks.removeAll { $0.id == id }
    if kind == .cli { f.store.restoreReceipt(row) } else { f.store.restoreAIReceipt(row) }
    return .init(store: kind, invocationID: id)
}

@MainActor private func saveAttemptCommand(_ f: WorkflowIntegrationFixture, marker: URL? = nil) throws -> SavedCommand {
    let value = SavedCommand(name: "Synthetic saved command", executable: marker == nil ? "/usr/bin/printf" : "/usr/bin/touch",
        arguments: marker.map { [$0.path] } ?? ["Synthetic CLI output"], workingDirectory: f.directory.path)
    #expect(f.store.saveCommand(value))
    return value
}

@MainActor @Suite(.serialized) struct AttemptPreparationIntegrationTests {
    @Test(arguments: [false, true])
    func terminalInvocationStillWaitsForItsWorkerOwnership(_ isAI: Bool) async throws {
        try await withAttemptFixture { f, _ in
            f.store.configuration.endpoint = "http://127.0.0.1:9/unused"
            f.store.configuration.localHTTP = true; f.store.configuration.model = "synthetic-owner-model"
            let definition: SavedRunDefinition
            if isAI {
                var agent = AgentDefinition(); agent.name = "Synthetic owned agent"
                #expect(f.store.saveAgent(agent))
                agent = try #require(f.store.configuration.agents.first { $0.id == agent.id })
                definition = .agent(agent)
            } else { definition = .command(try saveAttemptCommand(f)) }
            let journal = isAI ? f.store.aiInvocationStore : f.store.invocationStore, id = UUID()
            let begun = try await journal.begin(id: id, name: "Synthetic terminal but owned", runDefinition: definition.reference)
            try await journal.finish(id: id, result: .init(state: .succeeded), expectedRunStamp: begun.runStamp)
            let receipt = try #require(await journal.list().first { $0.id == id })
            if isAI { f.store.restoreAIReceipt(receipt) } else { f.store.restoreReceipt(receipt) }
            #expect(f.store.taskHandles[id] == nil && !f.store.executionReservations.contains(id))
            let early = try await f.executionIsDrained(id); #expect(!early)
            let presentation = AttemptPreparationPresentation(.init(store: isAI ? .ai : .cli, invocationID: id))
            await presentation.refresh(in: f.store)?.value
            #expect(presentation.phase == .needsReview && presentation.review == nil)
            #expect(presentation.notice == noticeKey("The previous worker is still finishing. Wait, then review again."))
            await journal.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
            let closed = try await f.executionIsDrained(id); #expect(closed)
            await presentation.refresh(in: f.store)?.value
            #expect(presentation.phase == .ready && presentation.review != nil)
        }
    }

    @Test(arguments: ["ai", "agent"])
    func actualAIAndAgentUseNewInputAndCurrentRateWithoutAutomaticCopy(_ kind: String) async throws {
        let server = try StoreSSEServer(); defer { server.stop() }
        try await withAttemptFixture { f, _ in
            let store = f.store
            store.configuration.endpoint = server.endpoint("attempt-echo"); store.configuration.localHTTP = true
            store.configuration.model = "synthetic-attempt-model"
            let firstRate = AIRateDefinition(endpointFingerprint: AIServiceIdentity.fingerprint(try #require(URL(string: store.configuration.endpoint))), model: store.configuration.model,
                currency: "USD", inputPerMillion: "2", outputPerMillion: "4")
            #expect(store.saveAIRate(firstRate, replacing: nil))
            var action = AIActionPreset(name: "Synthetic saved AI", prompt: "Use only this synthetic input.")
            #expect(store.saveAction(action))
            var agent = AgentDefinition(); agent.name = "Synthetic saved agent"
            #expect(store.saveAgent(agent))
            agent = try #require(store.configuration.agents.first { $0.id == agent.id })
            let oldID: UUID
            if kind == "ai" { oldID = try #require(store.runAI(action: action, draft: store.createDraft(input: "Synthetic OLD input", source: .manual))) }
            else { oldID = try #require(store.runAgent(agent, input: "Synthetic OLD input")) }
            try await f.drain(oldID)
            let oldTask = try f.task(oldID)
            #expect(oldTask.output.contains("Synthetic OLD input") && oldTask.runAttempt != nil)
            #expect(oldTask.aiUsageSummary?.cost.amounts.first?.amount == "0.000044")
            // 当前定义允许复制；恢复路径仍必须展示。fixture会把任何系统写入计为失败。
            action.output = .copy; #expect(store.saveAction(action))
            let original = try #require(store.configuration.aiRates.first)
            var newer = original; newer.inputPerMillion = "10"; newer.outputPerMillion = "10"
            #expect(store.saveAIRate(newer, replacing: original))
            let session = WorkspaceSession(); session.prepareAttempt(oldID, in: store)
            let presentation = try #require(session.attemptPreparation)
            await presentation.refresh(in: store)?.value
            #expect(presentation.phase == .ready && presentation.input.isEmpty)
            presentation.editInput("Synthetic NEW input")
            await presentation.confirm(try #require(presentation.review?.id), in: store)?.value
            let newID = try #require(presentation.admittedTaskID); try await f.drain(newID)
            let newTask = try f.task(newID)
            #expect(newTask.status == .completed && newTask.output.contains("Synthetic NEW input") && !newTask.output.contains("Synthetic OLD input"))
            #expect(newTask.runAttempt?.recoveryOf == oldID && newTask.aiUsageSummary?.cost.amounts.first?.amount == "0.00017")
            #expect(store.latestAutoCopyRunID == nil && store.resultTargets[newID] == nil && newTask.notice.isEmpty)
            #expect(try f.task(oldID).output == oldTask.output && f.task(oldID).aiUsageSummary == oldTask.aiUsageSummary)
            #expect(try await server.stats()["post_requests"] == 2)
        }
    }

    @Test(arguments: [false, true])
    func realStdioContractChangeOrJournalGapBlocksModelDispatch(_ journalGap: Bool) async throws {
        let server = try StoreSSEServer(); defer { server.stop() }
        try await withAttemptFixture { f, io in
            let store = f.store
            store.configuration.endpoint = server.endpoint("attempt-echo"); store.configuration.localHTTP = true; store.configuration.model = "synthetic-attempt-model"
            let descriptor = f.directory.appendingPathComponent("description.txt"), marker = f.directory.appendingPathComponent("started.txt")
            try Data("Synthetic reviewed echo".utf8).write(to: descriptor)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let script = root.appendingPathComponent("Packages/MCPAdapters/Tests/MCPAdaptersTests/mcp_stdio_fixture.py")
            let source = MCPServerConfiguration(name: "Synthetic owned stdio", stdio: .init(executable: "/usr/bin/python3", arguments: ["-I", "-S", "-u", script.path, "attempt-contract", descriptor.path, marker.path], workingDirectory: f.directory.path), enabled: true)
            store.configuration.mcpServers = [source]
            let client = try store.makeMCPClient(source)
            let catalog = try await client.discover(); await client.invalidate()
            store.mcpCatalogs[source.id] = catalog
            try FileManager.default.removeItem(at: marker)
            var agent = AgentDefinition(); agent.name = "Synthetic MCP attempt"; agent.allowedMCPServerIDs = [source.id]
            agent.allowedMCPToolNames = [try #require(catalog.tools.first?.definition.name)]
            #expect(store.saveAgent(agent)); agent = try #require(store.configuration.agents.first { $0.id == agent.id })
            let origin = try await seedAttempt(f, definition: .agent(agent)), review = try await store.reviewAttempt(origin)
            #expect(!FileManager.default.fileExists(atPath: marker.path) && review.scopePreview.contains("Synthetic reviewed echo"))
            if journalGap { io.hold("tools") }
            else { try Data("Synthetic CHANGED echo".utf8).write(to: descriptor) }
            let owner = try await store.admitAttempt(review, input: "Synthetic NEW input", isCurrent: { true })
            if journalGap {
                try await f.eventually { io.entered }
                let language = store.configuration.language
                store.configuration.language = "en"; store.configuration.language = language
                io.release()
            }
            try await f.drain(owner.id)
            #expect(try f.task(owner.id).status == .failed)
            #expect(try await server.stats()["post_requests"] == 0)
            #expect(store.mcpRunClients[owner.id] == nil && store.pendingApprovals.isEmpty)
            if journalGap {
                #expect(!FileManager.default.fileExists(atPath: marker.path))
                #expect(await store.agentToolStore.list().contains { $0.message == "mcp.connectionNotDispatched" && $0.state == .cancelled })
            } else { #expect(FileManager.default.fileExists(atPath: marker.path)) }
        }
    }
    @Test func preparationHasBlankIndependentInputAndNoEffectsOrSensitiveReads() async throws {
        let f = try WorkflowIntegrationFixture(allowContextCapture: true)
        await f.stopAutomaticWork()
        do {
            let value = try saveAttemptCommand(f), origin = try await seedAttempt(f, definition: .command(value))
            let sourceBytes = try Data(contentsOf: f.directory.appendingPathComponent("invocations/invocations.json"))
            let count = f.store.tasks.count, drafts = f.store.drafts.count
            let presentation = AttemptPreparationPresentation(origin)
            await presentation.refresh(in: f.store)?.value
            #expect(presentation.phase == .ready && presentation.input.isEmpty)
            #expect(presentation.review?.allowsInput == false && presentation.review?.scopePreview.contains("/usr/bin/printf") == true)
            #expect(f.store.tasks.count == count && f.store.drafts.count == drafts && f.store.executionReservations.isEmpty)
            #expect(try Data(contentsOf: f.directory.appendingPathComponent("invocations/invocations.json")) == sourceBytes)
            presentation.invalidate()
            #expect(presentation.phase == .closed)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test func savedCLIUsesNewIDAndKeepsTheOldOutcome() async throws {
        try await withAttemptFixture { f, _ in
            let command = try saveAttemptCommand(f), origin = try await seedAttempt(f, definition: .command(command))
            let old = try #require(await f.store.invocationStore.list().first { $0.id == origin.invocationID })
            let review = try await f.store.reviewAttempt(origin)
            let accepted = try await f.store.admitAttempt(review, input: "", isCurrent: { true })
            #expect(accepted.id != origin.invocationID && accepted.begun.runStamp != nil)
            try await f.drain(accepted.id)
            #expect(try f.task(accepted.id).status == .completed && f.task(accepted.id).output == "Synthetic CLI output")
            let rows = await f.store.invocationStore.list(), source = try #require(rows.first { $0.id == old.id })
            let child = try #require(rows.first { $0.id == accepted.id })
            #expect(source.state == old.state && source.finishedAt == old.finishedAt && source.exitCode == old.exitCode && source.message == old.message)
            #expect(child.runAttempt?.recoveryOf == old.id && child.runAttempt?.logicalRunID == old.id && source.runAttempt?.revision == 2)
            let count = rows.count
            do { _ = try await f.store.admitAttempt(review, input: "", isCurrent: { true }); Issue.record("Old review replayed") } catch {}
            #expect(await f.store.invocationStore.list().count == count)
        }
    }
    @Test func pureWorkflowUsesOnlyNewInputAndPreservesEditorDrafts() async throws {
        try await withAttemptFixture { f, _ in
            let workflow = WorkflowDefinition(name: "Synthetic uppercase", steps: [.init(operation: .transform(.uppercase))])
            #expect(f.store.saveWorkflow(workflow))
            let origin = try await seedAttempt(f, definition: .workflow(workflow)), session = WorkspaceSession()
            session.workflowInput = "Old editor input"; session.agentInput = "Old agent input"
            session.prepareAttempt(origin.invocationID, in: f.store)
            let presentation = try #require(session.attemptPreparation)
            await presentation.refresh(in: f.store)?.value
            #expect(presentation.input.isEmpty && !presentation.canSubmit(in: f.store))
            presentation.editInput("new synthetic input")
            let reviewID = try #require(presentation.review?.id)
            let submission = try #require(presentation.confirm(reviewID, in: f.store))
            #expect(presentation.confirm(reviewID, in: f.store) == nil)
            await submission.value
            let accepted = try #require(presentation.admittedTaskID)
            try await f.drain(accepted)
            #expect(try f.task(accepted).output == "NEW SYNTHETIC INPUT")
            #expect(session.workflowInput == "Old editor input" && session.agentInput == "Old agent input")
            #expect(await f.store.aiInvocationStore.list().first { $0.id == accepted }?.runAttempt?.recoveryOf == origin.invocationID)
        }
    }
    @Test func literalWorkflowAllowsBlankInputWithoutInventingOldOutput() async throws {
        try await withAttemptFixture { f, _ in
            let workflow = WorkflowDefinition(name: "Synthetic literal", steps: [.init(operation: .transform(.trim), input: .literal(" fixed synthetic "))])
            #expect(f.store.saveWorkflow(workflow))
            let origin = try await seedAttempt(f, definition: .workflow(workflow)), presentation = AttemptPreparationPresentation(origin)
            await presentation.refresh(in: f.store)?.value
            #expect(presentation.review?.requiresInput == false && presentation.canSubmit(in: f.store))
            await presentation.confirm(try #require(presentation.review?.id), in: f.store)?.value
            let id = try #require(presentation.admittedTaskID); try await f.drain(id)
            #expect(try f.task(id).output == "fixed synthetic")
        }
    }
    @Test func refreshPreservesUTF8InputAndRejectsOldReviewsAndConfigurationABA() async throws {
        try await withAttemptFixture { f, _ in
            let workflow = WorkflowDefinition(name: "Synthetic text", steps: [.init(operation: .transform(.trim))])
            #expect(f.store.saveWorkflow(workflow))
            let origin = try await seedAttempt(f, definition: .workflow(workflow)), presentation = AttemptPreparationPresentation(origin)
            await presentation.refresh(in: f.store)?.value
            let oldReview = try #require(presentation.review?.id)
            presentation.editInput("Caf\u{e9}"); let revision = presentation.inputRevision
            presentation.editInput("Cafe\u{301}")
            #expect(presentation.inputRevision != revision)
            presentation.editInput(String(repeating: "中", count: TaskTextLimits.inputBytes))
            #expect(presentation.inputRejected && presentation.input.utf8.elementsEqual("Cafe\u{301}".utf8))
            presentation.editInput("Cafe\u{301}"); #expect(!presentation.inputRejected)
            let language = f.store.configuration.language
            f.store.configuration.language = "en"; f.store.configuration.language = language
            presentation.validateReview(in: f.store); #expect(presentation.phase == .needsReview)
            #expect(presentation.confirm(oldReview, in: f.store) == nil)
            await presentation.refresh(in: f.store)?.value
            #expect(presentation.phase == .ready && presentation.input.utf8.elementsEqual("Cafe\u{301}".utf8))
            #expect(presentation.review?.id != oldReview && presentation.confirm(oldReview, in: f.store) == nil)
        }
    }
    @Test(arguments: [InvocationPersistencePoint.beforeWrite, .beforeRename, .afterRename])
    func intentFailureNeverExecutesTheOwnedMarker(_ point: InvocationPersistencePoint) async throws {
        try await withAttemptFixture { f, io in
            let marker = f.directory.appendingPathComponent("must-not-exist"), command = try saveAttemptCommand(f, marker: marker)
            let origin = try await seedAttempt(f, definition: .command(command)), review = try await f.store.reviewAttempt(origin)
            let oldBytes = try Data(contentsOf: f.directory.appendingPathComponent("invocations/invocations.json"))
            io.fail(point)
            do { _ = try await f.store.admitAttempt(review, input: "", isCurrent: { true }); Issue.record("Failed intent was admitted") } catch {}
            try await f.eventually { f.store.taskHandles.isEmpty && f.store.executionReservations.isEmpty }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            if point != .afterRename { #expect(try Data(contentsOf: f.directory.appendingPathComponent("invocations/invocations.json")) == oldBytes) }
            io.fail(nil); await f.store.maintainTaskHistory()
        }
    }
    @Test func configurationABAWhileIntentWritesBlocksDispatchAfterAwait() async throws {
        try await withAttemptFixture { f, io in
            let marker = f.directory.appendingPathComponent("must-not-run"), command = try saveAttemptCommand(f, marker: marker)
            let origin = try await seedAttempt(f, definition: .command(command)), review = try await f.store.reviewAttempt(origin)
            io.hold()
            let submission = Task { try await f.store.admitAttempt(review, input: "", isCurrent: { true }) }
            try await f.eventually { io.entered }
            let language = f.store.configuration.language
            f.store.configuration.language = "en"; f.store.configuration.language = language
            io.release()
            do { _ = try await submission.value; Issue.record("Stale submission was admitted") } catch {}
            try await f.eventually { f.store.taskHandles.isEmpty }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }
    @Test func admittedSelectionSurvivesLateCancelAndForcedWindowClose() async throws {
        try await withAttemptFixture { f, _ in
            let command = try saveAttemptCommand(f), origin = try await seedAttempt(f, definition: .command(command)), session = WorkspaceSession()
            session.prepareAttempt(origin.invocationID, in: f.store)
            let presentation = try #require(session.attemptPreparation)
            await presentation.refresh(in: f.store)?.value
            session.attemptPreparationDidAppear(presentation.id)
            await presentation.confirm(try #require(presentation.review?.id), in: f.store)?.value
            let accepted = try #require(presentation.admittedTaskID)
            session.cancelAttemptPreparation(presentation.id)
            #expect(presentation.admittedTaskID == accepted && session.hasPendingOrDismissingModal)
            session.invalidateAttemptPreparation()
            session.attemptPreparationDidDismiss(presentation.id)
            #expect(session.selectedTaskID == accepted && session.attemptPreparation == nil)
            try await f.drain(accepted); #expect(try f.task(accepted).status == .completed)
        }
    }
    @Test func unknownRequiresAcknowledgmentAndLegacyHistoryCannotBeGuessed() async throws {
        try await withAttemptFixture { f, _ in
            let command = try saveAttemptCommand(f), origin = try await seedAttempt(f, definition: .command(command), state: .interrupted)
            let presentation = AttemptPreparationPresentation(origin)
            await presentation.refresh(in: f.store)?.value
            #expect(presentation.review?.requiresEffectAcknowledgment == true && !presentation.canSubmit(in: f.store))
            presentation.effectsChecked = true; #expect(presentation.canSubmit(in: f.store))
            let id = UUID(); try await f.store.invocationStore.begin(id: id, name: command.name, commandID: "command." + command.id.uuidString)
            try await f.store.invocationStore.finish(id: id, result: .init(state: .succeeded)); await f.store.invocationStore.releaseProtection(for: id)
            do { _ = try await f.store.reviewAttempt(.init(store: .cli, invocationID: id)); Issue.record("Legacy title was used as authority") }
            catch { #expect(error as? InvocationStoreError == .recoveryUnavailable) }
        }
    }
    @Test func modalOwnersStayExclusiveUntilTheirActualDismissal() async throws {
        try await withAttemptFixture { f, _ in
            let command = try saveAttemptCommand(f), origin = try await seedAttempt(f, definition: .command(command)), session = WorkspaceSession()
            let workflow = WorkflowDefinition(name: "Synthetic workflow", steps: [.init(operation: .transform(.trim))])
            #expect(f.store.saveWorkflow(workflow))
            f.store.configuration.collections = [try .init(name: "Synthetic collection", commandIDs: ["workflow." + workflow.id.uuidString])]
            let collection = try #require(f.store.configuration.collections.first)
            session.prepareAttempt(origin.invocationID, in: f.store)
            let owner = try #require(session.attemptPreparation)
            session.attemptPreparationDidAppear(owner.id)
            session.cancelAttemptPreparation(owner.id)
            #expect(session.hasPendingOrDismissingModal && !session.canPresentSourceRemoval)
            #expect(!session.prepareWorkflowLaunch(workflow.id, in: f.store))
            session.prepareToolRemoval(.collection(collection.id), in: f.store); #expect(session.savedToolRemoval == nil)
            session.attemptPreparationDidDismiss(owner.id)
            #expect(session.prepareWorkflowLaunch(workflow.id, in: f.store))
            let launch = try #require(session.workflowLaunch); launch.appeared = true; session.cancelWorkflowLaunch(launch.id)
            session.prepareAttempt(origin.invocationID, in: f.store); #expect(session.attemptPreparation == nil)
            session.workflowLaunchDidDismiss(launch.id)
            session.prepareAttempt(origin.invocationID, in: f.store)
            let next = try #require(session.attemptPreparation)
            session.attemptPreparationDidDismiss(owner.id); #expect(session.attemptPreparation === next)
            session.invalidateAttemptPreparation()
        }
    }
    @Test func historyClearInvalidatesReviewAndRetainsIndependentInput() async throws {
        try await withAttemptFixture { f, _ in
            let workflow = WorkflowDefinition(name: "Synthetic clear", steps: [.init(operation: .transform(.trim))])
            #expect(f.store.saveWorkflow(workflow))
            let origin = try await seedAttempt(f, definition: .workflow(workflow)), session = WorkspaceSession(), store = f.store
            store.onAttemptHistoryChanged = { [weak session, weak store] removed in guard let store else { return }; session?.attemptHistoryChanged(removed, in: store) }
            session.prepareAttempt(origin.invocationID, in: store)
            let owner = try #require(session.attemptPreparation); await owner.refresh(in: store)?.value
            owner.editInput("Keep synthetic draft"); let reviewID = try #require(owner.review?.id)
            await store.clearFinishedHistory()
            #expect(owner.input == "Keep synthetic draft" && owner.confirm(reviewID, in: store) == nil)
            await owner.refresh(in: store)?.value; #expect(owner.phase == .unavailable)
            #expect(store.executionReservations.isEmpty)
        }
    }
    @Test func agentAndWorkflowScopesDescribeActualDefinitions() async throws {
        try await withAttemptFixture { f, _ in
            let command = try saveAttemptCommand(f)
            f.store.configuration.endpoint = "http://127.0.0.1:9/synthetic"; f.store.configuration.model = "synthetic-model"; f.store.configuration.localHTTP = true
            var agent = AgentDefinition(); agent.name = "Synthetic scoped agent"; agent.allowedCommandIDs = [command.id]
            #expect(f.store.saveAgent(agent))
            let origin = try await seedAttempt(f, definition: .agent(agent)), review = try await f.store.reviewAttempt(origin)
            #expect(review.scopePreview.contains("/usr/bin/printf") && review.scopePreview.contains(agent.instructions))
            #expect(review.lines.contains { $0.kind == .command && $0.value == command.name })
            let workflow = WorkflowDefinition(name: "Synthetic ordered scope", steps: [.init(operation: .savedCommand(command.id)), .init(operation: .transform(.uppercase), input: .previousOutput)])
            #expect(f.store.saveWorkflow(workflow))
            let workflowOrigin = try await seedAttempt(f, definition: .workflow(workflow)), scope = try await f.store.reviewAttempt(workflowOrigin)
            #expect(scope.scopePreview.contains("1. " + command.name) && scope.scopePreview.contains("2. ") && scope.scopePreview.contains("/usr/bin/printf"))
            #expect(f.store.executionReservations.isEmpty)
        }
    }
}
