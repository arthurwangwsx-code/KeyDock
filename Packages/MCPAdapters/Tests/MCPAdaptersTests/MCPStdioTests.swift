import Foundation
import Testing
import AICore
@testable import MCPAdapters

@Suite(.serialized) struct MCPStdioTests {
    private func configuration(mode: String = "normal", version: MCPProtocolVersion = .modern20260728, timeout: TimeInterval = 5) -> MCPServerConfiguration {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("mcp_stdio_fixture.py")
        return MCPServerConfiguration(name: "Synthetic stdio", stdio: .init(executable: "/usr/bin/python3", arguments: ["-I", "-S", "-u", script.path, mode], workingDirectory: "/tmp"), enabled: true, protocolVersion: version, timeoutSeconds: timeout)
    }
    @Test(arguments: [MCPProtocolVersion.modern20260728, .legacy20251125])
    func discoverToolAndExplicitContextThenGracefulShutdown(_ version: MCPProtocolVersion) async throws {
        let config = configuration(version: version), client = try MCPHTTPClient(configuration: config)
        let catalog = try await client.discover()
        let tool = try #require(catalog.tools.first)
        let result = try await client.call(modelToolName: tool.id, arguments: ["text": .string("Synthetic\n合成")], catalogRevision: catalog.revision)
        #expect(result.text == "Synthetic\n合成")
        let selected = MCPExplicitSourceSelection(serverID: config.id, configurationRevision: config.revision)
        let resources = try await client.listResources(selection: selected)
        let content = try await client.readResource(selection: resources.select(uri: resources.resources[0].uri))
        #expect(content.contents.first?.text == "Synthetic selected resource")
        let prompts = try await client.listPrompts(selection: selected)
        let prompt = try await client.getPrompt(selection: prompts.select(name: "synthetic"), arguments: ["text": "Synthetic prompt"])
        #expect(prompt.messages.first?.text == "Synthetic prompt")
        await client.invalidate()
    }
    @Test func cancellationSendsOnlyOriginalRequestIDAndRetainsNoStderrBody() async throws {
        let config = configuration(mode: "slow"), wire = try MCPStdioTransport(configuration: config)
        let client = try MCPHTTPClient(configuration: config, transport: wire)
        let catalog = try await client.discover()
        let task = Task { try await client.call(modelToolName: catalog.tools[0].id, arguments: ["text": .string("Synthetic")], catalogRevision: catalog.revision) }
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var statsID = 1000
        while true {
            statsID += 1
            let stats = try await wire.send(configuration: config, method: "synthetic/stats", params: [:], id: statsID, sessionID: nil)
            if stats.result["pending"] == .number(1) { break }
            guard ContinuousClock.now < startDeadline else { task.cancel(); throw MCPClientError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            statsID += 1
            let stats = try await wire.send(configuration: config, method: "synthetic/stats", params: [:], id: statsID, sessionID: nil)
            if stats.result["cancelled"] == .number(1) { break }
            guard ContinuousClock.now < closeDeadline else { throw MCPClientError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        await client.invalidate()
        let diagnostics = await wire.diagnostics()
        #expect(diagnostics.stderrBytesDiscarded > 0 && diagnostics.exited && !diagnostics.forcedTermination)
    }
    @Test(arguments: ["bad", "oversize"])
    func invalidOrOversizedProtocolOutputClosesOwnedProcess(mode: String) async throws {
        let config = configuration(mode: mode), wire = try MCPStdioTransport(configuration: config)
        let client = try MCPHTTPClient(configuration: config, transport: wire)
        do { _ = try await client.discover(); Issue.record("Invalid synthetic output was accepted") }
        catch { #expect(error is MCPClientError || error is CancellationError) }
        await client.invalidate()
        #expect(await wire.diagnostics().exited)
    }
    @Test func requestTimeoutIsBoundedAndLaterFramesCannotReviveIt() async throws {
        let config = configuration(mode: "delayed-start-slow", timeout: 1), wire = try MCPStdioTransport(configuration: config)
        let client = try MCPHTTPClient(configuration: config, transport: wire)
        let connecting = ContinuousClock.now
        let catalog = try await client.discover()
        #expect(connecting.duration(to:.now) >= .seconds(1))
        let started = ContinuousClock.now
        await #expect(throws: MCPClientError.timeout) {
            try await client.call(modelToolName: catalog.tools[0].id, arguments: ["text": .string("Synthetic")], catalogRevision: catalog.revision)
        }
        #expect(started.duration(to:.now) < .seconds(3))
        await client.invalidate()
        #expect(await wire.diagnostics().exited)
    }
    @Test func configurationRoundTripsAndLegacyHTTPDefaultsToHTTP() throws {
        let config = configuration(), encoder = JSONEncoder()
        let data = try encoder.encode(config)
        #expect(try JSONDecoder().decode(MCPServerConfiguration.self, from: data) == config)
        let http = MCPServerConfiguration(name: "Synthetic HTTP", endpoint: URL(string: "https://example.com/mcp")!)
        var value = try #require(JSONSerialization.jsonObject(with: encoder.encode(http)) as? [String: Any])
        value.removeValue(forKey: "transportKind"); value.removeValue(forKey: "stdioLaunch")
        let old = try JSONSerialization.data(withJSONObject: value)
        #expect(try JSONDecoder().decode(MCPServerConfiguration.self, from: old).transportKind == .http)
    }
    @Test func startupBudgetRoundTripsAndOldLaunchDataRetainsItsDefault() throws {
        let launch = MCPStdioLaunchConfiguration(executable:"/usr/bin/true",workingDirectory:"/tmp",startupTimeoutSeconds:17)
        let data = try JSONEncoder().encode(launch)
        #expect(try JSONDecoder().decode(MCPStdioLaunchConfiguration.self,from:data) == launch)
        var fields = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any]); fields.removeValue(forKey:"startupTimeoutSeconds")
        #expect(try JSONDecoder().decode(MCPStdioLaunchConfiguration.self,from:JSONSerialization.data(withJSONObject:fields)).startupTimeoutSeconds == 30)
        for invalid in [0.0,121.0,Double.infinity] {
            #expect(throws:MCPClientError.invalidConfiguration) { try MCPStdioLaunchConfiguration(executable:"/usr/bin/true",workingDirectory:"/tmp",startupTimeoutSeconds:invalid).validate() }
        }
    }
}
