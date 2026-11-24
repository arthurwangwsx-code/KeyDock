import Foundation
import Testing
import AICore
@testable import MCPAdapters

private let syntheticSchema: [String: JSONValue] = ["type": .string("object"), "properties": .object([
    "text": .object(["type": .string("string"), "maxLength": .number(128)])
]), "required": .array([.string("text")]), "additionalProperties": .bool(false)]

private actor ScriptedMCP: MCPHTTPTransporting {
    enum Behavior: Sendable, Equatable { case normal, repeatedCursor, holdCall, nonText, largeText }
    struct Record: Sendable { let method: String; let session: String? }
    let behavior: Behavior
    var records: [Record] = []
    var callStarted = false
    init(_ behavior: Behavior = .normal) { self.behavior = behavior }
    func waitForCall() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !callStarted {
            guard ContinuousClock.now < deadline else { throw MCPClientError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func snapshot() -> [Record] { records }
    func send(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue], id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
        records.append(.init(method: method, session: sessionID))
        func result(_ fields: [String: JSONValue], session: String? = nil) -> MCPHTTPReply {
            var fields = fields
            if configuration.protocolVersion == .modern20260728 { fields["resultType"] = .string("complete") }
            return MCPHTTPReply(result: fields, sessionID: session)
        }
        switch method {
        case "initialize":
            return result(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object([:])])], session: "synthetic-session")
        case "notifications/initialized": return result([:])
        case "server/discover": return result(["supportedVersions": .array([.string("2026-07-28")]), "capabilities": .object(["tools": .object([:])])])
        case "tools/list":
            if behavior == .repeatedCursor { return result(["tools": .array([]), "nextCursor": .string("same")]) }
            if params["cursor"] == nil {
                return result(["tools": .array([.object(["name": .string("echo"), "description": .string("Synthetic echo"),
                    "inputSchema": .object(syntheticSchema), "annotations": .object(["readOnlyHint": .bool(true)])])]), "nextCursor": .string("page2")])
            }
            return result(["tools": .array([.object(["name": .string("unsupported"), "inputSchema": .object(["oneOf": .array([])])])])])
        case "tools/call":
            callStarted = true
            if behavior == .holdCall { try await Task.sleep(for: .seconds(60)) }
            if behavior == .nonText { return result(["content": .array([.object(["type": .string("image"), "data": .string("synthetic")])])]) }
            let value = behavior == .largeText ? String(repeating: "a", count: 65_537) : params["arguments"]?.objectValue?["text"]?.stringValue ?? "missing"
            return result(["content": .array([.object(["type": .string("text"), "text": .string(value)])]), "isError": .bool(false)])
        default: throw MCPClientError.invalidResponse
        }
    }
}

@Suite(.serialized) struct MCPClientTests {
    private func configuration(_ version: MCPProtocolVersion = .modern20260728, enabled: Bool = true) -> MCPServerConfiguration {
        MCPServerConfiguration(name: "Synthetic MCP", endpoint: URL(string: "http://127.0.0.1:12345/mcp")!, allowsLocalHTTP: true, enabled: enabled, protocolVersion: version)
    }
    @Test(arguments: [MCPProtocolVersion.modern20260728, .legacy20251125])
    func discoverPaginateCallAndRejectUnsupportedSchemas(_ version: MCPProtocolVersion) async throws {
        let wire = ScriptedMCP(), client = try MCPHTTPClient(configuration: configuration(version), transport: wire)
        let catalog = try await client.discover()
        #expect(catalog.tools.count == 1 && catalog.rejectedTools.count == 1)
        #expect(catalog.rejectedTools.first?.reason == .unsupportedSchema)
        let tool = try #require(catalog.tools.first)
        #expect(tool.definition.name.utf8.count <= 64 && tool.definition.name.hasPrefix("mcp_"))
        let response = try await client.call(modelToolName: tool.id, arguments: ["text": .string("合成 input")], catalogRevision: catalog.revision)
        #expect(response.text == "合成 input" && !response.isError)
        let records = await wire.snapshot()
        #expect(records.filter { $0.method == "tools/list" }.count == 2)
        if version == .legacy20251125 {
            #expect(records.map(\.method).prefix(2) == ["initialize", "notifications/initialized"])
            #expect(records.filter { $0.method == "tools/list" || $0.method == "tools/call" }.allSatisfy { $0.session == "synthetic-session" })
        } else { #expect(records.first?.method == "server/discover" && records.allSatisfy { $0.session == nil }) }
    }
    @Test func catalogsAreScopedToSourceAndRefreshInvalidatesOldRevision() async throws {
        let wire = ScriptedMCP()
        let first = try MCPHTTPClient(configuration: configuration(), transport: wire)
        let second = try MCPHTTPClient(configuration: configuration(), transport: ScriptedMCP())
        let a = try await first.discover(), b = try await second.discover()
        #expect(a.tools.first?.id != b.tools.first?.id)
        let refreshed = try await first.discover()
        #expect(refreshed.revision != a.revision && refreshed.tools.first?.id == a.tools.first?.id)
        await #expect(throws: MCPClientError.catalogChanged) {
            try await first.call(modelToolName: a.tools[0].id, arguments: ["text": .string("test")], catalogRevision: a.revision)
        }
        #expect(await wire.snapshot().filter { $0.method == "tools/call" }.isEmpty)
    }
    @Test func invalidArgumentsAndDisabledSourcesNeverDispatchTools() async throws {
        let wire = ScriptedMCP(), client = try MCPHTTPClient(configuration: configuration(), transport: wire)
        let catalog = try await client.discover()
        await #expect(throws: MCPClientError.invalidArguments) {
            try await client.call(modelToolName: catalog.tools[0].id, arguments: ["unexpected": .string("test")], catalogRevision: catalog.revision)
        }
        #expect(await wire.snapshot().filter { $0.method == "tools/call" }.isEmpty)
        let disabledWire = ScriptedMCP(), disabled = try MCPHTTPClient(configuration: configuration(enabled: false), transport: disabledWire)
        await #expect(throws: MCPClientError.disabled) { try await disabled.discover() }
        #expect(await disabledWire.snapshot().isEmpty)
    }
    @Test func repeatedCursorFailsClosed() async throws {
        let client = try MCPHTTPClient(configuration: configuration(), transport: ScriptedMCP(.repeatedCursor))
        await #expect(throws: MCPClientError.invalidResponse) { try await client.discover() }
    }
    @Test func cancellationAndInvalidationStopOwnedRequestAndRejectOldCatalog() async throws {
        let wire = ScriptedMCP(.holdCall), client = try MCPHTTPClient(configuration: configuration(), transport: wire)
        let catalog = try await client.discover()
        let task = Task { try await client.call(modelToolName: catalog.tools[0].id, arguments: ["text": .string("test")], catalogRevision: catalog.revision) }
        try await wire.waitForCall()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await client.invalidate()
        await #expect(throws: MCPClientError.catalogChanged) {
            try await client.call(modelToolName: catalog.tools[0].id, arguments: ["text": .string("test")], catalogRevision: catalog.revision)
        }
    }
    @Test func unsupportedContentAndOversizedTextAreNotSilentlyDropped() async throws {
        for behavior in [ScriptedMCP.Behavior.nonText, .largeText] {
            let client = try MCPHTTPClient(configuration: configuration(), transport: ScriptedMCP(behavior))
            let catalog = try await client.discover()
            let expected: MCPClientError = behavior == .nonText ? .unsupportedContent : .limitExceeded
            await #expect(throws: expected) {
                try await client.call(modelToolName: catalog.tools[0].id, arguments: ["text": .string("test")], catalogRevision: catalog.revision)
            }
        }
    }
    @Test func remoteHTTPRequiresExplicitLoopbackAndHTTPS() throws {
        #expect(throws: MCPClientError.invalidConfiguration) {
            try MCPServerConfiguration(name: "test", endpoint: URL(string: "http://example.com/mcp")!, allowsLocalHTTP: true).validate()
        }
        #expect(throws: MCPClientError.invalidConfiguration) {
            try MCPServerConfiguration(name: "test", endpoint: URL(string: "http://127.0.0.1:12345/mcp")!).validate()
        }
    }
}
