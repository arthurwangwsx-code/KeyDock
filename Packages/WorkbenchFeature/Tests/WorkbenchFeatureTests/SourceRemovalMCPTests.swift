import Foundation
import Testing
import AgentCore
import AICore
import MCPAdapters
@testable import WorkbenchFeature

@MainActor @Suite(.serialized) struct SourceRemovalMCPTests {
    @Test(arguments: [false, true])
    func storedSourceOrOnlyNamespaceToolReferencesBlockWithoutRevocation(_ toolOnly: Bool) async throws {
        try await withSourceRemovalFixture { f, relay in
            let source = try makeRemovalMCP(in: f), transport = SourceRemovalTransport()
            let client = try MCPHTTPClient(configuration: source, transport: transport)
            f.store.mcpClients[source.id] = client
            var agent = AgentDefinition(); agent.name = "Synthetic referencing agent"
            if toolOnly { agent.allowedMCPToolNames = [MCPToolReference.prefix(source.id) + "0123456789abcdef"] }
            else { agent.allowedMCPServerIDs = [source.id] }
            f.store.configuration.agents = [agent]
            let writes = relay.writes, review = try await f.store.reviewSourceRemoval(.mcpServer(source.id))
            #expect(review.dependencies.map(\.objectID) == [agent.id])
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Referenced source was removed") }
            catch { #expect(error as? SourceRemovalError == .inUse) }
            #expect(!f.store.mcpSessionDisabled.contains(source.id) && relay.writes == writes)
            #expect(await transport.disconnects == 0)
            #expect(f.store.configuration.mcpServers == [source] && !f.store.mcpSettingsChanging)
        }
    }
    @Test(arguments: [SourceRemovalWriteRelay.Failure.before, .after])
    func failedRemovalKeepsDefinitionBytesButPausesAndClosesTheSession(_ mode: SourceRemovalWriteRelay.Failure) async throws {
        try await withSourceRemovalFixture { f, relay in
            let source = try makeRemovalMCP(in: f), transport = SourceRemovalTransport()
            f.store.mcpClients[source.id] = try MCPHTTPClient(configuration: source, transport: transport)
            let original = try Data(contentsOf: f.directory.appendingPathComponent("configuration.json"))
            let review = try await f.store.reviewSourceRemoval(.mcpServer(source.id)); relay.failure = mode
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Expected failed removal") }
            catch { if case SourceRemovalError.mcpPersistencePaused = error {} else { Issue.record("Unexpected failure: \(error)") } }
            #expect(try Data(contentsOf: f.directory.appendingPathComponent("configuration.json")) == original)
            #expect(f.store.configuration.mcpServers == [source] && f.store.mcpSessionDisabled.contains(source.id))
            #expect(await transport.disconnects == 1)
            #expect(f.store.mcpClients[source.id] == nil && f.store.mcpSettingsOwner == nil && !f.store.mcpSettingsChanging)
            await f.assertNoExecution()
        }
    }
    @Test func removalKeepsImportedTextDraftAndHistoryAndCannotBeRecreatedByOldDraft() async throws {
        try await withSourceRemovalFixture { f, _ in
            let source = try makeRemovalMCP(in: f), old = MCPServerDraft(source), session = WorkspaceSession()
            let token = try #require(f.store.beginTextContextImport(session))
            #expect(f.store.commitTextContext("Synthetic imported text", kind: .mcpResource, name: "Synthetic resource", session: session, token: token, mcpSourceID: source.id))
            let captured = session.toolsInput
            f.store.configuration.aiActions = [.init(name: "Synthetic summary", prompt: "Synthetic prompt")]
            let action = try #require(f.store.configuration.aiActions.first)
            let draft = try #require(f.store.createToolsDraft(actionID: action.id, session: session)), revision = draft.revision
            var history = RunningTaskItem(id: UUID(), title: "Synthetic retained history", state: .completed)
            history.output = "Synthetic retained output"; history.inputProvenance = captured.provenance
            f.store.tasks.append(history)
            let review = try await f.store.reviewSourceRemoval(.mcpServer(source.id))
            try await f.store.removeSource(review, isCurrent: { true })
            #expect(session.toolsInput.revision == captured.revision && session.toolsText == "Synthetic imported text")
            #expect(f.store.isRemovedMCPSource(session.toolsInput.provenance))
            #expect(draft.input == "Synthetic imported text" && draft.revision == revision && f.store.tasks.first?.output == "Synthetic retained output")
            #expect(await f.store.saveMCPServer(old) == false)
            await f.store.removeMCPServer(source.id)
            #expect(f.store.configuration.mcpServers.isEmpty && session.toolsText == "Synthetic imported text")
        }
    }
    @Test func oldCleanupCannotEraseAReplacementClientOrCatalog() async throws {
        try await withSourceRemovalFixture { f, _ in
            let source = try makeRemovalMCP(in: f), gate = SourceRemovalGate()
            defer { Task { await gate.release() } }
            let old = try MCPHTTPClient(configuration: source, transport: SourceRemovalTransport(closeGate: gate))
            let oldCatalog = try await old.discover()
            f.store.mcpClients[source.id] = old; f.store.mcpCatalogs[source.id] = oldCatalog
            let disconnect = Task { await f.store.disconnectMCP(source.id) }
            try await f.eventually { await gate.entered }
            #expect(f.store.mcpCatalogs[source.id] == nil)
            let replacement = try MCPHTTPClient(configuration: source, transport: SourceRemovalTransport(toolName: "new_synthetic_clock"))
            let newCatalog = try await replacement.discover()
            f.store.mcpSessionDisabled.remove(source.id); f.store.mcpClients[source.id] = replacement; f.store.mcpCatalogs[source.id] = newCatalog
            await gate.release(); await disconnect.value
            #expect(f.store.mcpCatalogs[source.id]?.revision == newCatalog.revision && f.store.mcpCatalogs[source.id]?.tools.first?.originalName == "new_synthetic_clock")
            #expect(f.store.mcpClients[source.id].map { $0 === replacement } == true)
        }
    }
    @Test func aRevokedSourceCannotCommitAnUncooperativeLateResourceRead() async throws {
        try await withSourceRemovalFixture { f, _ in
            let source = try makeRemovalMCP(in: f), gate = SourceRemovalGate(), session = WorkspaceSession()
            defer { Task { await gate.release() } }
            let client = try MCPHTTPClient(configuration: source, transport: SourceRemovalTransport(readGate: gate))
            _ = try await client.discover()
            let catalog = try await client.listResources(selection: .init(serverID: source.id, configurationRevision: source.revision))
            f.store.mcpClients[source.id] = client; f.store.mcpResources[source.id] = catalog
            let token = try #require(f.store.beginTextContextImport(session))
            #expect(f.store.commitTextContext("Keep prior synthetic input", kind: .textFile, name: "Prior.txt", session: session, token: token))
            let original = session.toolsInput
            f.store.readMCPResource(source.id, uri: "synthetic://owned/text", session: session)
            try await f.eventually { await gate.entered }
            let review = try await f.store.reviewSourceRemoval(.mcpServer(source.id))
            try await f.store.removeSource(review, isCurrent: { true })
            await gate.release(); try await f.eventually { !f.store.mcpBusy }
            #expect(session.toolsText == original.text && session.toolsInput.revision == original.revision && session.toolsInput.provenance == original.provenance)
            #expect(f.store.mcpResources[source.id] == nil && f.store.configuration.mcpServers.isEmpty)
        }
    }
    @Test func enabledSaveCannotUndoANewerDisconnect() async throws {
        try await withSourceRemovalFixture { f, _ in
            let source = try makeRemovalMCP(in: f), gate = SourceRemovalGate()
            defer { Task { await gate.release() } }
            f.store.mcpClients[source.id] = try MCPHTTPClient(configuration: source, transport: SourceRemovalTransport(closeGate: gate))
            let draft = MCPServerDraft(source)
            let saving = Task { await f.store.saveMCPServer(draft) }
            try await f.eventually { await gate.entered }
            await f.store.disconnectMCP(source.id)
            #expect(f.store.mcpSessionDisabled.contains(source.id))
            await gate.release(); #expect(await saving.value)
            #expect(f.store.configuration.mcpServers.first?.enabled == true && f.store.mcpSessionDisabled.contains(source.id))
            #expect(throws: MCPClientError.disabled) { try f.store.makeMCPClient(try #require(f.store.configuration.mcpServers.first)) }
        }
    }
    @Test func closingTheSettingsDoesNotLoseCommittedCleanupAndShutdownDrainsIt() async throws {
        try await withSourceRemovalFixture { f, _ in
            let source = try makeRemovalMCP(in: f), gate = SourceRemovalGate()
            defer { Task { await gate.release() } }
            f.store.mcpClients[source.id] = try MCPHTTPClient(configuration: source, transport: SourceRemovalTransport(closeGate: gate))
            let session = SettingsSession(store: f.store)
            session.prepareSourceRemoval(.mcpServer(source.id), in: f.store)
            let presentation = try #require(session.sourceRemoval)
            try await f.eventually { presentation.canConfirm }
            presentation.confirm(try #require(presentation.review?.id), in: f.store)
            try await f.eventually { await gate.entered }
            #expect(f.store.configuration.mcpServers.isEmpty && !f.store.configurationOperations.isEmpty)
            session.setVisible(false)
            var drained = false
            let shutdown = Task { await f.store.shutdownAndWait(); drained = true }
            try await f.eventually { f.store.isShuttingDown }
            #expect(!drained)
            await gate.release(); await shutdown.value
            #expect(drained && presentation.invalidated)
            try await f.eventually { f.store.configurationOperations.isEmpty }
        }
    }
    @Test(arguments: [false, true])
    func asyncSaveCannotClearAnotherDraftOrANewerKey(_ newDraft: Bool) async throws {
        try await withSourceRemovalFixture { f, _ in
            let source = try makeRemovalMCP(in: f), gate = SourceRemovalGate(), session = SettingsSession(store: f.store)
            defer { Task { await gate.release() } }
            f.store.mcpClients[source.id] = try MCPHTTPClient(configuration: source, transport: SourceRemovalTransport(closeGate: gate))
            session.mcpDraft = MCPServerDraft(source); session.mcpDraft.enabled = false
            let originalID = session.mcpDraft.presentationID
            let save = Task { await session.saveMCPDraft(in: f.store, trusted: false) }
            try await f.eventually { await gate.entered }
            if newDraft { session.mcpDraft = MCPServerDraft() }
            session.mcpDraft.apiKey = "SYNTHETIC NEW KEY"; session.mcpDraft.name = "Keep newer fields"
            await gate.release(); #expect(await save.value)
            #expect(session.mcpDraft.apiKey == "SYNTHETIC NEW KEY" && session.mcpDraft.name == "Keep newer fields")
            if newDraft { #expect(session.mcpDraft.presentationID != originalID && session.mcpDraft.editingRevision == nil) }
            else { #expect(session.mcpDraft.editingRevision == f.store.configuration.mcpServers.first?.revision) }
        }
    }
    @Test func staleTrustSubmissionAndRemovedSourceDraftHaveNoCredentialOrConnectionEffects() async throws {
        try await withSourceRemovalFixture { f, relay in
            let source = try makeRemovalMCP(in: f), session = SettingsSession(store: f.store), transport = SourceRemovalTransport()
            f.store.mcpClients[source.id] = try MCPHTTPClient(configuration: source, transport: transport)
            session.mcpDraft = MCPServerDraft(source)
            let submitted = session.mcpDraft, writes = relay.writes
            session.mcpDraft.endpoint = "https://example.com/another"
            #expect(await session.saveMCPDraft(submitted, in: f.store, trusted: true) == false)
            let disconnects = await transport.disconnects
            #expect(relay.writes == writes && !f.store.mcpSessionDisabled.contains(source.id) && disconnects == 0)
            let review = try await f.store.reviewSourceRemoval(.mcpServer(source.id))
            var changed = MCPServerDraft(source); changed.name = "Changed source"
            #expect(await f.store.saveMCPServer(changed))
            let freshWrites = relay.writes
            do { try await f.store.removeSource(review, isCurrent: { true }); Issue.record("Expected changed revision rejection") }
            catch { #expect(error as? SourceRemovalError == .changed) }
            #expect(relay.writes == freshWrites)
        }
    }
    @Test func agentReferencesValidateOfflineAndDisabledSourcesRemainSelectable() async throws {
        try await withSourceRemovalFixture { f, _ in
            let source = try makeRemovalMCP(in: f)
            var disabled = MCPServerDraft(source); disabled.enabled = false
            #expect(await f.store.saveMCPServer(disabled))
            var agent = AgentDefinition(); agent.allowedMCPServerIDs = [source.id]
            agent.allowedMCPToolNames = [MCPToolReference.prefix(source.id) + "0123456789abcdef"]
            #expect(f.store.saveAgent(agent))
            agent.allowedMCPServerIDs.insert(UUID())
            #expect(!f.store.saveAgent(agent))
            agent.allowedMCPServerIDs = []; #expect(!f.store.saveAgent(agent))
            agent.allowedMCPToolNames = []; #expect(f.store.saveAgent(agent))
            await f.assertNoExecution()
        }
    }
}
