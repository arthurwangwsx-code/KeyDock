import Foundation
import Testing
import AICore
import MacAdapters
@testable import WorkbenchFeature

private actor ControlledInventoryTransport: AIHTTPTransport {
    var requests: [URLRequest] = []
    var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    var cancelled = false, drained = false, releaseDrain = false
    var drainWaiter: CheckedContinuation<Void, Never>?
    func open(_ request: URLRequest) -> AIHTTPResponse {
        requests.append(request)
        let (body,c) = AsyncThrowingStream<Data,Error>.makeStream(); continuation = c
        return .init(statusCode:200,contentType:"application/json",body:body,cancel:{ Task { await self.cancel() } },waitForCompletion:{ await self.drain() })
    }
    func respond() { continuation?.yield(Data(#"{"object":"list","data":[{"id":"synthetic-discovered"}]}"#.utf8)); continuation?.finish() }
    func cancel() { cancelled = true; continuation?.finish(throwing:CancellationError()) }
    func drain() async { if !releaseDrain { await withCheckedContinuation { drainWaiter = $0 } }; drained = true }
    func finishDrain() { releaseDrain = true; drainWaiter?.resume(); drainWaiter = nil }
    func state() -> (Int,Bool,Bool) { (requests.count,cancelled,drained) }
    func header() -> String? { requests.first?.value(forHTTPHeaderField:"Authorization") }
}

@MainActor private func awaitInventory(_ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by:.seconds(3))
    while !(await condition()) { guard ContinuousClock.now < end else { throw URLError(.timedOut) }; try await Task.sleep(for:.milliseconds(5)) }
}

@Suite(.serialized) @MainActor struct AIModelInventoryFeatureTests {
    @Test func refreshIsExplicitAndDoesNotChangeModelsConfigurationOrUsage() async throws {
        let f = try RetentionFixture(); defer { Task { await f.cleanup() } }
        f.store.configuration.endpoint = "https://synthetic.invalid/v1/chat/completions"; f.store.configuration.model = "synthetic-selected-missing-from-list"
        let session = SettingsSession(store:f.store), transport = ControlledInventoryTransport()
        session.pane = .aiService; session.setVisible(true)
        let before = f.store.configuration, generation = f.store.configurationExportGeneration
        #expect(await transport.state().0 == 0 && session.modelInventory == nil)
        session.refreshModelInventory(in:f.store,client:.init(transport:transport))
        try await awaitInventory { await transport.state().0 == 1 }
        await transport.finishDrain(); await transport.respond()
        try await awaitInventory { !session.modelInventoryBusy }
        #expect(session.modelInventory?.models == [AIModelID("synthetic-discovered")])
        #expect(f.store.savedServiceModels == [AIModelID("synthetic-discovered")])
        #expect(session.modelName == before.model && f.store.configuration.model == before.model && f.store.configuration.aiModelSettings == before.aiModelSettings)
        #expect(f.store.configurationExportGeneration == generation && f.store.tasks.isEmpty && f.store.modelInventoryOperationIDs.isEmpty)
        #expect(await transport.header() == nil)
    }
    @Test(arguments:["endpointABA","keyABA","pane","hide","save","removeCredential","shutdown"])
    func invalidationRejectsLateResultsAndWaitsForDrain(_ mode:String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Inventory-"+UUID().uuidString)
        var reads = 0
        let store = try WorkbenchModel(dataDirectory:directory,allowContextCapture:true,clipboardReader:{nil},credentialReader:{ _ in reads += 1; return "synthetic-stored-key" },credentialWriter:{_,_ in },applicationCatalog:ApplicationCatalog(roots:[]))
        defer { Task { await store.shutdownAndWait(); try? FileManager.default.removeItem(at:directory) } }
        store.configuration.endpoint = "https://synthetic.invalid/v1/chat/completions"; store.configuration.model = "synthetic-model"
        let session = SettingsSession(store:store), transport = ControlledInventoryTransport()
        session.pane = .aiService; session.setVisible(true)
        let readsBefore = reads
        session.refreshModelInventory(in:store,client:.init(transport:transport))
        try await awaitInventory { await transport.state().0 == 1 }
        let authorization = await transport.header()
        #expect(reads == readsBefore + 1 && authorization == "Bearer synthetic-stored-key")
        switch mode {
        case "endpointABA": let original = session.endpoint; session.endpoint = "https://other.invalid/responses"; session.endpoint = original
        case "keyABA": session.apiKey = "synthetic-new-key"; session.apiKey = ""
        case "pane": session.pane = .general; session.pane = .aiService
        case "hide": session.setVisible(false); session.setVisible(true)
        case "save": _ = store.saveAPIConfiguration(endpoint:session.endpoint,modelName:session.modelName,localHTTP:false,tokenParameter:"max_completion_tokens",apiKey:"")
        case "removeCredential": store.removeCredential()
        default: store.shutdown()
        }
        try await awaitInventory { await transport.state().1 }
        #expect(session.modelInventoryBusy && !store.modelInventoryOperationIDs.isEmpty && store.modelInventoryWorkingBytes == 4_194_304)
        session.refreshModelInventory(in:store,client:.init(transport:transport))
        #expect(await transport.state().0 == 1)
        await transport.respond(); await transport.finishDrain()
        try await awaitInventory { !session.modelInventoryBusy && store.modelInventoryOperationIDs.isEmpty }
        let drained = await transport.state().2
        #expect(session.modelInventory == nil && drained && store.modelInventoryWorkingBytes == 0)
    }
    @Test func changedDraftEndpointNeverBorrowsSavedCredentialAndPreviewNeverReadsKeys() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Inventory-Key-"+UUID().uuidString)
        var reads = 0
        let store = try WorkbenchModel(dataDirectory:directory,allowContextCapture:true,clipboardReader:{nil},credentialReader:{ _ in reads += 1; return "synthetic-old-key" },applicationCatalog:ApplicationCatalog(roots:[]))
        defer { Task { await store.shutdownAndWait(); try? FileManager.default.removeItem(at:directory) } }
        store.configuration.endpoint = "https://old.invalid/v1/chat/completions"
        let session = SettingsSession(store:store); session.pane = .aiService; session.setVisible(true)
        session.apiKey = "synthetic-draft-key-for-old-service"
        session.endpoint = "https://new.invalid/v1/responses"
        #expect(session.apiKey.isEmpty)
        let transport = ControlledInventoryTransport(), before = reads
        session.refreshModelInventory(in:store,client:.init(transport:transport))
        try await awaitInventory { await transport.state().0 == 1 }
        let authorization = await transport.header()
        #expect(reads == before && authorization == nil)
        await transport.respond(); await transport.finishDrain()
        try await awaitInventory { !session.modelInventoryBusy }
        #expect(store.configuration.endpoint == "https://old.invalid/v1/chat/completions")
        #expect(store.savedServiceModels.isEmpty)
    }
    @Test func unsupportedPathNeverReadsCredentialsOrStartsNetwork() async throws {
        let f = try RetentionFixture(); defer { Task { await f.cleanup() } }
        let session = SettingsSession(store:f.store), transport = ControlledInventoryTransport()
        session.pane = .aiService; session.endpoint = "https://synthetic.invalid/custom?query=x"
        session.refreshModelInventory(in:f.store,client:.init(transport:transport))
        let count = await transport.state().0
        #expect(!session.modelInventoryBusy && count == 0)
    }
    @Test func metadataBudgetRejectsBeforeNetworkWithoutEvictingHistory() async throws {
        let f = try RetentionFixture(limits:.init(textBytes:2_000_000)); defer { Task { await f.cleanup() } }
        f.store.configuration.endpoint = "https://synthetic.invalid/responses"
        let session = SettingsSession(store:f.store), transport = ControlledInventoryTransport()
        session.pane = .aiService; session.setVisible(true)
        session.refreshModelInventory(in:f.store,client:.init(transport:transport))
        try await awaitInventory { !session.modelInventoryBusy }
        #expect(await transport.state().0 == 0)
        #expect(f.store.modelInventoryWorkingBytes == 0 && f.store.tasks.isEmpty)
    }
}
