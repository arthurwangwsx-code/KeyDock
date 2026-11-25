import Foundation
import Darwin
import Testing
import AICore
@testable import MCPAdapters

final class MCPLoopbackFixture {
    let baseURL: URL
    private let process: Process
    private let output: Pipe
    init() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("mcp_http_fixture.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw MCPClientError.invalidConfiguration }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-S", "-u", script.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        self.process = process; self.output = output
        try process.run()
        try? output.fileHandleForWriting.close()
        do {
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            var port = Data()
            let descriptor = output.fileHandleForReading.fileDescriptor
            while port.count < 6 {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw MCPClientError.timeout }
                var pollItem = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = Darwin.poll(&pollItem, 1, Int32(min(5000, (deadline-now)/1_000_000)))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw MCPClientError.transport }
                var byte: UInt8 = 0
                guard Darwin.read(descriptor, &byte, 1) == 1 else { throw MCPClientError.transport }
                if byte == 10 {
                    guard let number = Int(String(decoding: port, as: UTF8.self)), (1...65535).contains(number),
                          let url = URL(string: "http://127.0.0.1:\(number)") else { throw MCPClientError.invalidResponse }
                    baseURL = url
                    return
                }
                port.append(byte)
            }
            throw MCPClientError.invalidResponse
        } catch {
            Self.finish(process, output: output)
            throw error
        }
    }
    deinit { stop() }
    func stop() { Self.finish(process, output: output) }
    private static func finish(_ process: Process, output: Pipe) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
    func configuration(path: String, version: MCPProtocolVersion = .modern20260728, timeout: TimeInterval = 10, secret: String? = nil) -> MCPServerConfiguration {
        MCPServerConfiguration(name: "Synthetic wire MCP", endpoint: baseURL.appendingPathComponent(path), allowsLocalHTTP: true,
            enabled: true, protocolVersion: version, secretReference: secret, timeoutSeconds: timeout)
    }
    func stats() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("stats"))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
}
private struct SyntheticMCPSecret: MCPSecretProviding {
    func bearerToken(serverID: UUID, reference: String) async throws -> String? { "synthetic-test-credential" }
}

@Suite(.serialized) struct MCPWireTests {
    @Test(arguments: ["modern", "legacy", "sse"])
    func realURLSessionJSONOrSSEAndLegacySessionContract(path: String) async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let version: MCPProtocolVersion = path == "legacy" ? .legacy20251125 : .modern20260728
        let client = try MCPHTTPClient(configuration: server.configuration(path: path, version: version))
        let catalog = try await client.discover()
        let tool = try #require(catalog.tools.first)
        let result = try await client.call(modelToolName: tool.id, arguments: ["text": .string("Synthetic")], catalogRevision: catalog.revision)
        #expect(result.text == "Synthetic 合成")
        let stats = try await server.stats()
        #expect(stats["posts"] == (path == "legacy" ? 4 : 3))
        #expect(stats["authorization_seen"] == 0)
        if path != "legacy" { #expect(stats["valid_metadata"] == 3) }
    }
    @Test(arguments: ["modern", "legacy"])
    func explicitHTTPContextPreservesSourceAndMirrorsUnicodeNames(path: String) async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let version: MCPProtocolVersion = path == "legacy" ? .legacy20251125 : .modern20260728
        let configuration = server.configuration(path: path, version: version)
        let client = try MCPHTTPClient(configuration: configuration)
        _ = try await client.discover()
        let selected = MCPExplicitSourceSelection(serverID: configuration.id, configurationRevision: configuration.revision)
        let resources = try await client.listResources(selection: selected)
        let resource = try await client.readResource(selection: resources.select(uri: "synthetic://source/合成"))
        #expect(resource.contents.first?.text == "Synthetic selected HTTP context")
        let prompts = try await client.listPrompts(selection: selected)
        let prompt = try await client.getPrompt(selection: prompts.select(name: "合成提示"), arguments: ["text": "Synthetic HTTP prompt"])
        #expect(prompt.messages.first?.text == "Synthetic HTTP prompt")
        await client.invalidate()
    }
    @Test func redirectsDoNotForwardBearerAndResponseIDsMustMatch() async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let transport = MCPHTTPTransport(secrets: SyntheticMCPSecret())
        await #expect(throws: MCPClientError.httpStatus(302)) {
            try await transport.send(configuration: server.configuration(path: "redirect", secret: "synthetic-ref"), method: "server/discover", params: [:], id: 7, sessionID: nil)
        }
        await #expect(throws: MCPClientError.invalidResponse) {
            try await transport.send(configuration: server.configuration(path: "mismatch"), method: "server/discover", params: [:], id: 8, sessionID: nil)
        }
        let stats = try await server.stats()
        #expect(stats["redirect_hits"] == 0 && stats["authorization_seen"] == 1)
    }
    @Test func cancellationClosesTheRealSSEConnection() async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let configuration = server.configuration(path: "slow")
        let task = Task { try await MCPHTTPTransport().send(configuration: configuration, method: "server/discover", params: [:], id: 1, sessionID: nil) }
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await server.stats()["slow_open"] != 1 {
            guard ContinuousClock.now < startDeadline else { task.cancel(); throw MCPClientError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            let stats = try await server.stats()
            if stats["slow_closed"] == 1 { #expect(stats["slow_open"] == 0); break }
            guard ContinuousClock.now < closeDeadline else { Issue.record("Synthetic MCP stream did not close after cancellation"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func timeoutClosesTheRealSSEConnection() async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let transport = MCPHTTPTransport()
        await #expect(throws: MCPClientError.timeout) {
            try await transport.send(configuration: server.configuration(path: "slow", timeout: 1), method: "server/discover", params: [:], id: 1, sessionID: nil)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            let stats = try await server.stats()
            if stats["slow_closed"] == 1 { #expect(stats["slow_open"] == 0); break }
            guard ContinuousClock.now < deadline else { Issue.record("Synthetic MCP stream did not close after timeout"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
