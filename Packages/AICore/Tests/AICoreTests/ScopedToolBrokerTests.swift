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
