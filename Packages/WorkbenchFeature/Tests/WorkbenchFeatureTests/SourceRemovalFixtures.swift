import Foundation
import Testing
import AICore
import AutomationCore
import MacAdapters
import MCPAdapters
@testable import WorkbenchFeature

actor SourceRemovalGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor final class SourceRemovalWriteRelay {
    enum Failure: Sendable { case before, after }
    var failure: Failure?
    private(set) var writes = 0
    func write(_ data: Data, to url: URL) throws {
        writes += 1
        let mode = failure; failure = nil
        if mode == .before { throw CocoaError(.fileWriteUnknown) }
        try PrivateFiles.write(data, to: url)
        if mode == .after { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor func withSourceRemovalFixture(_ body: @MainActor (WorkflowIntegrationFixture, SourceRemovalWriteRelay) async throws -> Void) async throws {
    let relay = SourceRemovalWriteRelay()
    let fixture = try WorkflowIntegrationFixture(configurationWriter: { try relay.write($0, to: $1) })
    fixture.store.onShortcutConfigurationChanged = { _ in } // 合成注册端口，不调用Carbon或全局热键。
    await fixture.stopAutomaticWork()
    do { try await body(fixture, relay); await fixture.cleanup() }
    catch { await fixture.cleanup(); throw error }
}

@MainActor func makeRemovalWorkflow(in fixture: WorkflowIntegrationFixture, name: String = "Synthetic removable workflow") throws -> WorkflowDefinition {
    let definition = WorkflowDefinition(name: name, steps: [.init(operation: .transform(.trim))])
    #expect(fixture.store.saveWorkflow(definition))
    return try #require(fixture.store.configuration.workflows.first { $0.id == definition.id })
}

@MainActor func makeRemovalMCP(in fixture: WorkflowIntegrationFixture) throws -> MCPServerConfiguration {
    let source = MCPServerConfiguration(name: "Synthetic removable source", endpoint: URL(string: "https://example.com/mcp")!, enabled: true, secretReference: "SYNTHETIC-KEY-REFERENCE")
    var next = fixture.store.configuration; next.mcpServers = [source]
    #expect(fixture.store.commitSettingsConfiguration(next))
    return source
}

/// 纯内存传输；发现与退出均由本测试拥有，不连接任何真实endpoint。
actor SourceRemovalTransport: MCPHTTPTransporting {
    let closeGate: SourceRemovalGate?
    let readGate: SourceRemovalGate?
    let toolName: String
    private(set) var disconnects = 0
    init(closeGate: SourceRemovalGate? = nil, readGate: SourceRemovalGate? = nil, toolName: String = "synthetic_clock") { self.closeGate = closeGate; self.readGate = readGate; self.toolName = toolName }
    func send(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue], id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
        switch method {
        case "server/discover":
            return .init(result: ["supportedVersions": .array([.string(configuration.protocolVersion.rawValue)]), "capabilities": .object(["tools": .object([:]), "resources": .object([:])])])
        case "initialize":
            return .init(result: ["protocolVersion": .string(configuration.protocolVersion.rawValue), "capabilities": .object(["tools": .object([:])]), "serverInfo": .object(["name": .string("Owned synthetic source"), "version": .string("1")])])
        case "notifications/initialized": return .init(result: [:])
        case "tools/list":
            return .init(result: ["tools": .array([.object(["name": .string(toolName), "description": .string("Synthetic read only tool"), "inputSchema": .object(["type": .string("object"), "properties": .object([:])])])])])
        case "resources/list":
            return .init(result: ["resources": .array([.object(["uri": .string("synthetic://owned/text"), "name": .string("Synthetic owned text"), "mimeType": .string("text/plain")])])])
        case "resources/read":
            if let readGate { await readGate.wait() }
            return .init(result: ["contents": .array([.object(["uri": .string("synthetic://owned/text"), "mimeType": .string("text/plain"), "text": .string("Late synthetic resource must not be committed")])])])
        default: Issue.record("Unexpected synthetic MCP method: \(method)"); throw MCPClientError.transport
        }
    }
    func disconnect(configuration: MCPServerConfiguration) async { disconnects += 1; if let closeGate { await closeGate.wait() } }
}
