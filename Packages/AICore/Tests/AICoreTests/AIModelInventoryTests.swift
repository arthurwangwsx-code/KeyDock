import Foundation
import Testing
@testable import AICore

private actor InventoryTransport: AIHTTPTransport {
    let status: Int, type: String, bytes: Data
    var requests: [URLRequest] = []
    var drained = false
    init(_ bytes: Data, status: Int = 200, type: String = "application/json") { self.bytes = bytes; self.status = status; self.type = type }
    func open(_ request: URLRequest) -> AIHTTPResponse {
        requests.append(request)
        return .init(statusCode: status, contentType: type, body: .init { c in c.yield(bytes); c.finish() }, waitForCompletion: { await self.finish() })
    }
    func finish() { drained = true }
    func state() -> ([URLRequest], Bool) { (requests, drained) }
}

@Suite struct AIModelInventoryTests {
    @Test func exactIDsArePreservedAndNoCapabilitiesAreInferred() throws {
        let ids = ["synthetic-z", "café", "cafe\u{301}", "synthetic-z"]
        let bytes = try JSONSerialization.data(withJSONObject: ["object":"list", "data":ids.map { ["id":$0] }, "has_more":true])
        let result = try AIModelInventoryClient.decode(bytes)
        #expect(result.models.count == 3 && result.isPartial)
        #expect(Set(result.models).count == 3)
        #expect(result.models.contains(AIModelID(ids[1])) && result.models.contains(AIModelID(ids[2])))
        #expect(AIModelID(ids[1]) != AIModelID(ids[2]))
    }
    @Test(arguments: ["https://synthetic.invalid/proxy/v1/chat/completions", "https://synthetic.invalid/proxy/v1/responses"])
    func derivesOnlyExactSameOriginPrefix(_ value: String) throws {
        #expect(try AIModelInventoryClient.listEndpoint(for: URL(string:value)!, allowsLocalHTTP: false).absoluteString == "https://synthetic.invalid/proxy/v1/models")
    }
    @Test(arguments: ["https://synthetic.invalid/unknown", "https://synthetic.invalid/v1/responses?key=x", "https://user@synthetic.invalid/v1/responses", "http://synthetic.invalid/v1/responses", "https://synthetic.invalid/v1/responses#fragment", "https://synthetic.invalid/v1/%72esponses"])
    func refusesAmbiguousOrUnsafeEndpoints(_ value: String) {
        #expect(throws: (any Error).self) { try AIModelInventoryClient.listEndpoint(for: URL(string:value)!, allowsLocalHTTP: true) }
    }
    @Test(arguments: ["", "  ", "synthetic\nmodel", "synthetic\0model", String(repeating:"x",count:257)])
    func refusesInvalidIDs(_ id: String) throws {
        let bytes = try JSONSerialization.data(withJSONObject: ["object":"list", "data":[["id":id]]])
        #expect(throws: (any Error).self) { try AIModelInventoryClient.decode(bytes) }
    }
    @Test func emptyListsAreValidButOversizedAndMalformedListsAreNot() throws {
        #expect(try AIModelInventoryClient.decode(Data(#"{"object":"list","data":[]}"#.utf8)).models.isEmpty)
        for text in [#"{"object":"other","data":[]}"#, #"{"object":"list","data":[{}]}"#, #"{"object":"list","data":[{"id":12}]}"#] {
            #expect(throws: (any Error).self) { try AIModelInventoryClient.decode(Data(text.utf8)) }
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["object":"list", "data":(0..<513).map { ["id":"synthetic-\($0)"] }])
        #expect(throws: (any Error).self) { try AIModelInventoryClient.decode(bytes) }
        #expect(throws: (any Error).self) { try AIModelInventoryClient.decode(Data(repeating:32,count:1_048_577)) }
    }
    @Test func getRequestUsesExactKeyAndDrainsWithoutSendingTextOrChangingSettings() async throws {
        let transport = InventoryTransport(Data(#"{"object":"list","data":[{"id":"synthetic-new"}]}"#.utf8))
        let result = try await AIModelInventoryClient(transport:transport).list(endpoint:URL(string:"https://synthetic.invalid/v1/responses")!, allowsLocalHTTP:false, apiKey:"synthetic-test-key")
        let (requests, drained) = await transport.state(), request = try #require(requests.first)
        #expect(result.models == [AIModelID("synthetic-new")] && drained)
        #expect(requests.count == 1 && request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.url?.path == "/v1/models" && request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-test-key")
    }
    @Test(arguments: [302,401,429,500]) func errorBodiesAreIgnoredAndDrained(_ status: Int) async throws {
        let transport = InventoryTransport(Data("synthetic-private-error-body".utf8), status:status)
        do { _ = try await AIModelInventoryClient(transport:transport).list(endpoint:URL(string:"https://synthetic.invalid/responses")!, allowsLocalHTTP:false, apiKey:""); Issue.record("Expected HTTP rejection") }
        catch { #expect((error as? AIProviderError) == .httpStatus(status)) }
        #expect(await transport.state().1)
    }
    @Test func invalidContentAndLargeBodyDrain() async throws {
        for (bytes,type) in [(Data("synthetic".utf8),"text/plain"),(Data(repeating:32,count:1_048_577),"application/json")] {
            let transport = InventoryTransport(bytes,type:type)
            do { _ = try await AIModelInventoryClient(transport:transport).list(endpoint:URL(string:"https://synthetic.invalid/responses")!, allowsLocalHTTP:false, apiKey:""); Issue.record("Expected bounded rejection") } catch {}
            #expect(await transport.state().1)
        }
    }
}
