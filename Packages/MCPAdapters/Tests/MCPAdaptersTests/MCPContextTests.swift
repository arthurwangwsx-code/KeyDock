import Foundation
import Testing
import AICore
@testable import MCPAdapters

private actor ContextMCPWire: MCPHTTPTransporting {
    enum Mode: Sendable { case normal, wrongURI, systemRole }
    let mode: Mode
    var methods: [String] = []
    init(_ mode: Mode = .normal) { self.mode = mode }
    func calls() -> [String] { methods }
    func send(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue], id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
        methods.append(method)
        let result: [String: JSONValue]
        switch method {
        case "server/discover":
            result = ["supportedVersions": .array([.string("2026-07-28")]), "capabilities": .object(["resources": .object([:]), "prompts": .object([:])])]
        case "resources/list":
            if params["cursor"] == nil {
                result = ["resources": .array([.object(["uri": .string("synthetic://source/合成"), "name": .string("Synthetic")])]), "nextCursor": .string("second")]
            } else { result = ["resources": .array([.object(["uri": .string("synthetic://source/two"), "name": .string("Two")])])] }
        case "resources/read":
            result = ["contents": .array([.object(["uri": mode == .wrongURI ? .string("synthetic://source/unselected") : params["uri"]!, "text": .string("Synthetic selected text")])])]
        case "prompts/list":
            result = ["prompts": .array([.object(["name": .string("合成提示"), "arguments": .array([.object(["name": .string("text"), "required": .bool(true)])])])])]
        case "prompts/get":
            result = ["messages": .array([.object(["role": .string(mode == .systemRole ? "system" : "user"), "content": .object(["type": .string("text"), "text": params["arguments"]?.objectValue?["text"] ?? .string("")])])])]
        default: throw MCPClientError.invalidResponse
        }
        var complete = result; complete["resultType"] = .string("complete")
        return .init(result: complete)
    }
}

@Suite(.serialized) struct MCPContextTests {
    private func configuration() -> MCPServerConfiguration {
        .init(name: "Synthetic context source", endpoint: URL(string: "https://example.com/mcp")!, enabled: true)
    }
    @Test func resourceOnlySourceNeedsExplicitSelectionAndDoesNotAdvertiseTools() async throws {
        let config = configuration(), wire = ContextMCPWire()
        let client = try MCPHTTPClient(configuration: config, transport: wire)
        let tools = try await client.discover()
        #expect(tools.tools.isEmpty)
        #expect(await client.availableCapabilities() == ["resources", "prompts"])
        await #expect(throws: MCPClientError.selectionRequired) {
            try await client.listResources(selection: .init(serverID: UUID(), configurationRevision: config.revision))
        }
        #expect(await wire.calls() == ["server/discover"])
        let source = MCPExplicitSourceSelection(serverID: config.id, configurationRevision: config.revision)
        let catalog = try await client.listResources(selection: source)
        #expect(catalog.resources.count == 2)
        let selected = try catalog.select(uri: "synthetic://source/合成")
        let result = try await client.readResource(selection: selected)
        #expect(result.contents.first?.text == "Synthetic selected text")
        _ = try await client.listResources(selection: source)
        let before = await wire.calls().count
        await #expect(throws: MCPClientError.catalogChanged) { try await client.readResource(selection: selected) }
        #expect(await wire.calls().count == before)
    }
    @Test func aSelectedResourceDoesNotAuthorizeUnexpectedReturnedURIs() async throws {
        let config = configuration(), client = try MCPHTTPClient(configuration: config, transport: ContextMCPWire(.wrongURI))
        _ = try await client.discover()
        let catalog = try await client.listResources(selection: .init(serverID: config.id, configurationRevision: config.revision))
        await #expect(throws: MCPClientError.selectionRequired) {
            try await client.readResource(selection: catalog.select(uri: catalog.resources[0].uri))
        }
    }
    @Test func promptsRequireListedArgumentsAndNeverGrantSystemRole() async throws {
        for mode in [ContextMCPWire.Mode.normal, .systemRole] {
            let config = configuration(), wire = ContextMCPWire(mode), client = try MCPHTTPClient(configuration: config, transport: wire)
            _ = try await client.discover()
            let catalog = try await client.listPrompts(selection: .init(serverID: config.id, configurationRevision: config.revision))
            let selected = try catalog.select(name: "合成提示")
            await #expect(throws: MCPClientError.invalidArguments) { try await client.getPrompt(selection: selected, arguments: ["unknown": "x"]) }
            #expect(!(await wire.calls()).contains("prompts/get"))
            if mode == .normal {
                let result = try await client.getPrompt(selection: selected, arguments: ["text": "Synthetic prompt"])
                #expect(result.messages.first?.role == .user && result.messages.first?.text == "Synthetic prompt")
            } else {
                await #expect(throws: MCPClientError.unsupportedContent) {
                    try await client.getPrompt(selection: selected, arguments: ["text": "Synthetic prompt"])
                }
            }
        }
    }
    @Test func headerMirroringSafelyEncodesUnicodeWhitespaceAndLiteralSentinels() {
        #expect(MCPHeaderValue.encode("synthetic://safe/one") == "synthetic://safe/one")
        for value in ["合成提示", " padded ", "line\nvalue", "=?base64?literal?="] {
            let encoded = MCPHeaderValue.encode(value)
            #expect(encoded.hasPrefix("=?base64?") && encoded.hasSuffix("?="))
            let base64 = String(encoded.dropFirst(9).dropLast(2))
            #expect(Data(base64Encoded: base64).map { String(decoding: $0, as: UTF8.self) } == value)
        }
    }
}
