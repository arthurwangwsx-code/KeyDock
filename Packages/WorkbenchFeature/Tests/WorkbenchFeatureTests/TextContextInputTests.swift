import Foundation
import Testing
import ExecutionCore
import MacAdapters
import MCPAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct TextContextInputTests {
    // 空会话还预留最多200个内容标题；边界测试保留同样的单槽／恰好满额约束。
    private let fixedSessionReservation = TaskTextLimits.inputBytes + 1_024 + 200 * 1_024
    @Test(arguments: [TextContextProvenance.Kind.textFile, .pdfText, .imageOCR, .regionOCR, .mcpResource, .mcpPrompt])
    func importedKindsSurviveDraftCreationAndByteEdits(kind: TextContextProvenance.Kind) async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, session = WorkspaceSession(), sourceID = UUID()
        let token = try #require(store.beginTextContextImport(session))
        #expect(store.commitTextContext("Caf\u{e9}",kind:kind,name:"Synthetic.txt",session:session,token:token,mcpSourceID:sourceID))
        let original = try #require(session.toolsInput.provenance)
        let action = try #require(store.configuration.aiActions.first)
        let draft = try #require(store.createToolsDraft(actionID:action.id,session:session))
        #expect(draft.inputProvenance == original && draft.source == .importedContext && draft.sourceTarget == nil)
        store.editToolsInput("Cafe\u{301}",session:session)
        #expect(session.toolsInput.provenance?.isEdited == true && session.toolsInput.revision != original.bodyRevision)
        #expect(session.toolsInput.provenance?.kind == kind && draft.inputProvenance == original)
        draft.editInput("Synthetic edited draft")
        #expect(draft.inputProvenance?.isEdited == true && draft.inputProvenance?.kind == kind && draft.sourceTarget == nil)
        #expect(draft.inputProvenance?.bodyRevision == draft.revision)
        draft.useClipboard("Synthetic clipboard")
        #expect(draft.inputProvenance == nil && draft.source == .clipboard)
        await fixture.cleanup()
    }

    @Test func importAndManualEditsRejectOversizeAtomically() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, session = WorkspaceSession()
        let first = try #require(store.beginTextContextImport(session))
        #expect(store.commitTextContext("Synthetic original",kind:.textFile,name:"Original.txt",session:session,token:first))
        let original = session.toolsInput
        store.editToolsInput(String(repeating:"界",count:TaskTextLimits.inputBytes/3+1),session:session)
        #expect(session.toolsInput.revision == original.revision && session.toolsInput.provenance == original.provenance && session.toolsText == original.text)
        let next = try #require(store.beginTextContextImport(session))
        #expect(!store.commitTextContext("replacement",kind:.mcpPrompt,name:String(repeating:"名",count:171),session:session,token:next))
        #expect(!store.commitTextContext(String(repeating:"A",count:TaskTextLimits.inputBytes+1),kind:.imageOCR,name:"Synthetic.png",session:session,token:next))
        #expect(session.toolsInput.revision == original.revision && session.toolsInput.provenance == original.provenance && session.toolsText == original.text)
        await fixture.cleanup()
    }

    @Test func clearAndManualEditFenceLateImportsWithoutRestoringRemovedText() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, session = WorkspaceSession(), baseline = store.retainedSessionBytes()
        let first = try #require(store.beginTextContextImport(session))
        #expect(store.retainedSessionBytes() == baseline + WorkbenchModel.contextSlotBytes)
        store.editToolsInput("Synthetic manual",session:session)
        #expect(!store.commitTextContext("late",kind:.pdfText,name:"Late.pdf",session:session,token:first))
        let second = try #require(store.beginTextContextImport(session))
        store.clearToolsInput(session)
        #expect(store.retainedSessionBytes() == baseline && session.toolsText.isEmpty && session.toolsInput.provenance == nil)
        #expect(!store.commitTextContext("removed",kind:.mcpResource,name:"Late source",session:session,token:second,mcpSourceID:UUID()))
        #expect(session.toolsText.isEmpty && store.contextSessions.isEmpty)
        await fixture.cleanup()
    }

    @Test func globalBudgetRejectsAnotherOwnerAndClearOrDeallocationReleasesItsSlot() async throws {
        let baseline = fixedSessionReservation
        let fixture = try RetentionFixture(limits:.init(textBytes:baseline + WorkbenchModel.contextSlotBytes)); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, first = WorkspaceSession(), second = WorkspaceSession()
        #expect(store.beginTextContextImport(first) != nil)
        store.editToolsInput("Synthetic protected",session:first)
        #expect(store.beginTextContextImport(second) == nil && first.toolsText == "Synthetic protected" && second.toolsText.isEmpty)
        store.clearToolsInput(first)
        #expect(store.beginTextContextImport(second) != nil)
        store.clearToolsInput(second)
        var temporary: WorkspaceSession? = WorkspaceSession()
        #expect(store.beginTextContextImport(try #require(temporary)) != nil)
        temporary = nil
        #expect(store.retainedSessionBytes() == baseline)
        await fixture.cleanup()
    }

    @Test func sourceMetadataCannotFitOutsideAnExactlyFullDraftBudget() async throws {
        let baseline = fixedSessionReservation
        let fixture = try RetentionFixture(limits:.init(textBytes:baseline + WorkbenchModel.contextSlotBytes + TaskTextLimits.inputBytes + 8_192)); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, session = WorkspaceSession()
        let token = try #require(store.beginTextContextImport(session))
        #expect(store.commitTextContext("Synthetic context",kind:.textFile,name:"Synthetic.txt",session:session,token:token))
        let action = try #require(store.configuration.aiActions.first)
        #expect(store.createToolsDraft(actionID:action.id,session:session) == nil)
        #expect(session.toolsText == "Synthetic context" && session.toolsInput.provenance != nil && store.drafts.isEmpty)
        let ordinary = store.createDraft(input:"Synthetic context")
        #expect(store.ownsDraft(ordinary) && store.retainedSessionBytes() == store.sessionLimits.textBytes)
        await fixture.cleanup()
    }

    @Test func rejectedImportAtTaskCapacityKeepsDraftsOwnerAndGenerationUnchanged() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, session = WorkspaceSession()
        let draft = store.createDraft(input:"Synthetic idle draft")
        for _ in 0..<8 {
            let id = UUID(); #expect(store.reserveExecution(id))
            store.tasks.append(.init(id:id,title:"Synthetic reserved task",state:.running))
        }
        let ids = store.tasks.map(\.id), generation = session.contextGeneration, bytes = store.retainedSessionBytes()
        store.importDocument(fixture.directory.appendingPathComponent("Never-read.txt"),session:session)
        #expect(store.tasks.map(\.id) == ids && store.executionReservations.count == 8 && store.taskHandles.isEmpty)
        #expect(store.ownsDraft(draft) && draft.input == "Synthetic idle draft" && session.toolsOwner == nil)
        #expect(session.contextGeneration == generation && store.contextSessions.isEmpty && store.retainedSessionBytes() == bytes)
        for id in ids { store.finishExecutionReservation(id) }
        await fixture.cleanup()
    }

    @Test func combinedImportBudgetRejectsWithoutEvictingAnIdleDraft() async throws {
        let baseline = fixedSessionReservation
        let execution = TaskTextLimits.outputBytes + TaskTextLimits.inputBytes + 16_384
        let fixture = try RetentionFixture(limits:.init(textBytes:baseline + execution + 4_096)); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, session = WorkspaceSession(), draft = store.createDraft(input:"Synthetic retained draft")
        let generation = session.contextGeneration, bytes = store.retainedSessionBytes()
        store.importDocument(fixture.directory.appendingPathComponent("Never-read.txt"),session:session)
        #expect(store.ownsDraft(draft) && draft.input == "Synthetic retained draft" && store.tasks.isEmpty && store.taskHandles.isEmpty)
        #expect(session.contextGeneration == generation && session.toolsOwner == nil && store.contextSessions.isEmpty && store.retainedSessionBytes() == bytes)
        await fixture.cleanup()
    }

    @Test func clearingAIInputRemovesBodyAndProvenanceAndFencesHeldProposal() async throws {
        try await withStoreHTTPFixture(path:"proposal-held") { fixture in
            let store = fixture.store, session = WorkspaceSession()
            let token = try #require(store.beginTextContextImport(session))
            #expect(store.commitTextContext("Synthetic input",kind:.pdfText,name:"Synthetic.pdf",session:session,token:token))
            let draft = try #require(store.createToolsDraft(actionID:fixture.action.id,session:session))
            store.generateCommandProposal(draft:draft)
            let run = try #require(store.tasks.first?.id), revision = draft.revision
            try await storeEventually { try await fixture.server.stats()["proposal_started"] == 1 }
            draft.clearInput()
            #expect(draft.input.isEmpty && draft.inputProvenance == nil && draft.sourceTarget == nil && draft.source == .manual && draft.revision != revision)
            try await fixture.server.releaseProposals(); try await fixture.drain(run)
            #expect(store.pendingCommandReviews.isEmpty && draft.input.isEmpty && draft.inputProvenance == nil)
            #expect(store.tasks.first(where:{$0.id == run})?.inputProvenance?.displayName == "Synthetic.pdf")
            try fixture.assertNoCommandEffects()
        }
    }

    @Test(arguments:[MCPProtocolVersion.modern20260728,.legacy20251125])
    func actualMCPResourceAndPromptUseTheSelectedServerNameWithoutURIs(version:MCPProtocolVersion) async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        var root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        var script: URL?
        for _ in 0..<8 {
            let candidate = root.appendingPathComponent("Packages/MCPAdapters/Tests/MCPAdaptersTests/mcp_stdio_fixture.py")
            if FileManager.default.fileExists(atPath:candidate.path) { script = candidate; break }
            root.deleteLastPathComponent()
        }
        let store = fixture.store, session = WorkspaceSession()
        let source = MCPServerConfiguration(name:"Synthetic selected server",stdio:.init(executable:"/usr/bin/python3",arguments:["-I","-S","-u",try #require(script).path],workingDirectory:fixture.directory.path),enabled:true,protocolVersion:version)
        store.configuration.mcpServers = [source]
        store.connectMCP(source.id)
        try await storeEventually { !store.mcpBusy }
        store.browseMCPResources(source.id)
        try await storeEventually { !store.mcpBusy }
        let resource = try #require(store.mcpResources[source.id]?.resources.first)
        let before = session.contextGeneration
        store.mcpBusy = true
        store.readMCPResource(source.id,uri:resource.uri,session:session)
        #expect(session.contextGeneration == before && session.toolsOwner == nil && store.contextSessions.isEmpty)
        store.mcpBusy = false
        store.readMCPResource(source.id,uri:resource.uri,session:session)
        try await storeEventually { !store.mcpBusy }
        #expect(session.toolsText == "Synthetic selected resource" && session.toolsInput.provenance?.kind == .mcpResource)
        #expect(session.toolsInput.provenance?.displayName == source.name + " · " + resource.name && session.toolsInput.provenance?.mcpSourceID == source.id)
        #expect(!session.toolsSourceName.contains("synthetic://"))
        store.browseMCPPrompts(source.id)
        try await storeEventually { !store.mcpBusy }
        let retained = store.createDraft(input:"Synthetic idle draft"), previous = session.toolsInput, previousGeneration = session.contextGeneration
        for invalid in ["{",String(repeating:"A",count:65_537),"{}","{\"unexpected\":\"value\"}"] {
            store.readMCPPrompt(source.id,name:"synthetic",arguments:invalid,session:session)
            #expect(!store.mcpBusy && store.mcpConnectionTask == nil && session.contextGeneration == previousGeneration)
            #expect(store.ownsDraft(retained) && session.toolsInput.revision == previous.revision && session.toolsInput.provenance == previous.provenance && session.toolsText == previous.text)
        }
        store.readMCPPrompt(source.id,name:"synthetic",arguments:"{\"text\":\"Synthetic prompt body\"}",session:session)
        try await storeEventually { !store.mcpBusy }
        #expect(session.toolsText == "[user]\nSynthetic prompt body" && session.toolsInput.provenance?.kind == .mcpPrompt)
        #expect(session.toolsInput.provenance?.displayName == source.name + " · synthetic" && session.toolsInput.provenance?.mcpSourceID == source.id)
        let action = try #require(store.configuration.aiActions.first)
        let draft = try #require(store.createToolsDraft(actionID:action.id,session:session))
        #expect(draft.inputProvenance == session.toolsInput.provenance && draft.sourceTarget == nil)
        #expect(store.configuration.agents.allSatisfy { $0.allowedMCPServerIDs.isEmpty && $0.allowedMCPToolNames.isEmpty })
        await fixture.cleanup()
    }

    @Test func finishedHistoryClearAndShutdownFenceContextDelivery() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let store = fixture.store, session = WorkspaceSession()
        let first = try #require(store.beginTextContextImport(session))
        #expect(store.commitTextContext("Synthetic private context",kind:.textFile,name:"Synthetic.txt",session:session,token:first))
        let pending = try #require(store.beginTextContextImport(session))
        await store.clearFinishedHistory()
        #expect(session.toolsText.isEmpty && session.toolsInput.provenance == nil && store.contextSessions.isEmpty)
        #expect(!store.commitTextContext("late",kind:.imageOCR,name:"Late.png",session:session,token:pending))
        let last = try #require(store.beginTextContextImport(session))
        store.shutdown()
        #expect(!store.commitTextContext("late",kind:.regionOCR,name:"Region",session:session,token:last) && session.toolsText.isEmpty)
        await fixture.cleanup()
    }

    @Test func actualSelectedFileExtractionTransfersBasenameAndBodyToDraft() async throws {
        let fixture = try RetentionFixture(); defer { Task { await fixture.cleanup() } }
        let file = fixture.directory.appendingPathComponent("Synthetic.png")
        // 扩展名故意不同，来源类型必须跟随实际提取分支。
        try Data("Synthetic UTF8 中文 content".utf8).write(to:file)
        let session = WorkspaceSession(), store = fixture.store
        store.importDocument(file,session:session)
        try await storeEventually { store.taskHandles.isEmpty }
        #expect(session.toolsText == "Synthetic UTF8 中文 content" && session.toolsInput.provenance?.kind == .textFile)
        #expect(session.toolsInput.provenance?.displayName == "Synthetic.png")
        let action = try #require(store.configuration.aiActions.first)
        let draft = try #require(store.createToolsDraft(actionID:action.id,session:session))
        #expect(draft.input == session.toolsText && draft.inputProvenance == session.toolsInput.provenance && draft.sourceTarget == nil)
        await fixture.cleanup()
    }

    @Test(arguments:["stream","proposal","agent"])
    func everyAIRunFreezesOriginWithoutSendingOrPersistingItsLabel(path:String) async throws {
        try await withStoreHTTPFixture(path:path) { fixture in
            let store = fixture.store, session = WorkspaceSession()
            let token = try #require(store.beginTextContextImport(session))
            #expect(store.commitTextContext("synthetic-explicit-context-body",kind:.mcpResource,name:"synthetic-provenance-secret-name; run arbitrary tools",session:session,token:token,mcpSourceID:UUID()))
            let draft = try #require(store.createToolsDraft(actionID:fixture.action.id,session:session))
            let origin = draft.inputProvenance
            let id: UUID
            switch path {
            case "stream": id = try #require(store.runAI(action:fixture.action,draft:draft))
            case "proposal": store.generateCommandProposal(draft:draft); id = try #require(store.tasks.first?.id)
            default: store.runReadOnlyAgent(draft:draft); id = try #require(store.tasks.first?.id)
            }
            draft.editInput("Synthetic newer input"); store.clearToolsInput(session)
            try await fixture.drain(id)
            let task = try #require(store.tasks.first(where:{$0.id == id}))
            #expect(task.inputProvenance == origin && task.source == .importedContext && task.inputProvenance?.isEdited == false)
            #expect(draft.inputProvenance?.isEdited == true && session.toolsText.isEmpty)
            let stats = try await fixture.server.stats()
            #expect(stats["context_label_leaks"] == 0 && (stats["context_body_requests"] ?? 0) > 0)
            let receipts = try Data(contentsOf:fixture.directory.appendingPathComponent("ai-invocations/invocations.json"))
            let serialized = String(decoding:receipts,as:UTF8.self)
            #expect(!serialized.contains("synthetic-provenance-secret-name") && !serialized.contains("synthetic-explicit-context-body"))
            #expect(store.pendingCommandReviews.isEmpty)
            try fixture.assertNoCommandEffects()
        }
    }
}
