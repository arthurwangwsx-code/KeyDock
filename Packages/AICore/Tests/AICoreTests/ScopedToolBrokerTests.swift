import Foundation
import Testing
import AICore
import AgentCore
import ExecutionCore

private actor CallCounter { var count = 0; func increment() { count += 1 } }
private actor ApprovalWaiter {
    var continuation: CheckedContinuation<Bool, any Error>?
    var ready = false
    func wait() async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                if Task.isCancelled { c.resume(throwing:CancellationError()) }
                else { continuation = c; ready = true }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func cancel() { let c = continuation; continuation = nil; c?.resume(throwing:CancellationError()) }
    func approveLate() { let c = continuation; continuation = nil; c?.resume(returning:true) }
}

@Suite(.serialized) struct ScopedToolBrokerTests {
    @Test func displayNamesRemainSeparateFromDispatchIdentityForSameNamedTools() async throws {
        let (directory, journal) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let counter = CallCounter(), title = "Synthetic shared title"
        let tools = ["synthetic_a", "synthetic_b"].map { name in
            ScopedAITool(definition: .init(name: name, description: "Synthetic test", parameters: ["type":.string("object"),"properties":.object([:]),"required":.array([]),"additionalProperties":.bool(false)]),
                effects: [.writeFile], resource: .exact(namespace: "synthetic.file", identifier: name), approvalSummary: "Synthetic arguments", displayTitle: title) { _, _ in
                await counter.increment(); return name
            }
        }
        let broker = try ScopedToolBroker(runID: UUID(), tools: tools, journal: journal) { proposal in
            #expect(proposal.displayTitle == title)
            #expect(["synthetic_a", "synthetic_b"].contains(proposal.toolName))
            return true
        }
        await #expect(throws: AIProviderError.unknownTool) { try await broker.invoke(.init(id: "bad", name: title, arguments: "{}"), allowed: [title, "synthetic_a", "synthetic_b"]) }
        #expect(await counter.count == 0)
        for name in ["synthetic_a", "synthetic_b"] {
            let output = try await broker.invoke(.init(id: name, name: name, arguments: "{}"), allowed: ["synthetic_a", "synthetic_b"])
            #expect(output == name)
        }
        #expect(await counter.count == 2)
        let definitions = await broker.definitions(), object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(definitions)) as? [[String: Any]])
        #expect(definitions.map(\.name) == ["synthetic_a", "synthetic_b"])
        #expect(object.allSatisfy { $0["displayTitle"] == nil })
    }

    @Test(arguments: ["", " \n ", "Synthetic\nname", String(repeating: "🙂", count: 200), String(repeating: "e\u{301}", count: 300), String(repeating: "a", count: 511) + "🙂"])
    func hostTitlesHaveBoundedValidSingleLinePreviews(_ title: String) {
        let proposal = AgentToolApproval(id: UUID(), runID: UUID(), toolName: "synthetic_protocol", summary: "Synthetic", effects: [.writeFile], displayTitle: title)
        #expect(proposal.displayTitle.utf8.count <= 512)
        #expect(!proposal.displayTitle.contains("\n") && !proposal.displayTitle.contains("\u{fffd}"))
        #expect(proposal.toolName == "synthetic_protocol")
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { #expect(proposal.displayTitle == proposal.toolName) }
    }

    @Test func defaultDisplayTitlePreservesOldApprovalCallers() {
        let proposal = AgentToolApproval(id: UUID(), runID: UUID(), toolName: "legacy_protocol", summary: "Synthetic", effects: [.writeFile])
        #expect(proposal.displayTitle == "legacy_protocol")
    }
    func fixture() throws -> (URL,InvocationStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-scoped-broker-"+UUID().uuidString)
        return (directory,try InvocationStore(directory:directory))
    }
    private func tool(counter: CallCounter, journal: InvocationStore) -> ScopedAITool {
        ScopedAITool(definition:.init(name:"synthetic_write",description:"Synthetic test effect",parameters:["type":.string("object"),"properties":.object([:]),"required":.array([]),"additionalProperties":.bool(false)]),effects:[.writeFile],resource:.exact(namespace:"synthetic.file",identifier:"owned-fixture"),approvalSummary:"Synthetic test write") { _,id in
            #expect(await journal.list().contains { $0.id == id && $0.state == .running })
            await counter.increment(); return "Synthetic result"
        }
    }
    @Test func denialAndSchemaRejectionCannotCreateAnIntentOrDispatch() async throws {
        let (directory,journal) = try fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        let counter = CallCounter(), broker = try ScopedToolBroker(runID:UUID(),tools:[tool(counter:counter,journal:journal)],journal:journal) { _ in false }
        await #expect(throws:AgentToolError.denied) { try await broker.invoke(.init(id:"denied",name:"synthetic_write",arguments:"{}"),allowed:["synthetic_write"]) }
        await #expect(throws:AIProviderError.invalidToolArguments) { try await broker.invoke(.init(id:"bad",name:"synthetic_write",arguments:"{\"unexpected\":true}"),allowed:["synthetic_write"]) }
        #expect(await counter.count == 0); #expect(await journal.list().isEmpty)
    }
    @Test func approvalIsBoundToOneCallAndIntentPrecedesDispatch() async throws {
        let (directory,journal) = try fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        let counter = CallCounter(), broker = try ScopedToolBroker(runID:UUID(),tools:[tool(counter:counter,journal:journal)],journal:journal) { _ in true }
        let call = AIToolCall(id:"once",name:"synthetic_write",arguments:"{}")
        #expect(try await broker.invoke(call,allowed:["synthetic_write"]) == "Synthetic result")
        await #expect(throws:AgentToolError.duplicateCall) { try await broker.invoke(call,allowed:["synthetic_write"]) }
        #expect(await counter.count == 1)
        let receipts = await journal.list(); #expect(receipts.count == 1 && receipts[0].state == .succeeded)
    }
    @Test func cancellationRejectsLateApprovalAndNeverDispatches() async throws {
        let (directory,journal) = try fixture(); defer { try? FileManager.default.removeItem(at:directory) }
        let counter = CallCounter(), gate = ApprovalWaiter()
        let broker = try ScopedToolBroker(runID:UUID(),tools:[tool(counter:counter,journal:journal)],journal:journal) { _ in try await gate.wait() }
        let task = Task { try await broker.invoke(.init(id:"cancel",name:"synthetic_write",arguments:"{}"),allowed:["synthetic_write"]) }
        for _ in 0..<100 { if await gate.ready { break }; try await Task.sleep(for:.milliseconds(10)) }
        #expect(await gate.ready); task.cancel()
        if case .success = await task.result { Issue.record("Cancelled approval unexpectedly succeeded") }
        await gate.approveLate()
        #expect(await counter.count == 0); #expect(await journal.list().isEmpty)
    }
    @Test func agentWritesNeedExplicitInvocationBoundApproval() throws {
        let id = UUID()
        let request = ExecutionRequest(invocationID:id,commandID:"test.command",commandVersion:1,toolID:"test.tool",toolVersion:1,caller:.agent,callerInstanceID:"test-run",resourceScope:.exact(namespace:"test.file",identifier:"fixture"),effects:[.writeFile])
        let reusable = PolicyGrant(caller:.agent,callerInstanceID:"test-run",commandID:request.commandID,commandVersion:1,toolID:request.toolID,toolVersion:1,resourceScope:request.resourceScope,allowedEffects:request.effects,expiresAt:.distantFuture,sideEffectsApproved:true,agentInvocationApproved:true)
        #expect(throws:ExecutionPolicyError.agentWriteUnsupported) { try ExecutionPolicy.authorize(request:request,grant:reusable) }
        let exact = PolicyGrant(caller:.agent,callerInstanceID:"test-run",commandID:request.commandID,commandVersion:1,toolID:request.toolID,toolVersion:1,resourceScope:request.resourceScope,allowedEffects:request.effects,expiresAt:.distantFuture,sideEffectsApproved:true,invocationID:id,agentInvocationApproved:true)
        try ExecutionPolicy.authorize(request:request,grant:exact)
    }
}
