import Foundation
import Testing
import AICore
@testable import MCPAdapters

private actor RevocableSyntheticMCPSecret: MCPSecretProviding {
    private var revoked = false
    private var reads = 0
    func bearerToken(serverID: UUID, reference: String) async throws -> String? {
        reads += 1
        guard !revoked else { throw MCPClientError.missingCredential }
        return "synthetic-test-credential"
    }
    func revoke() { revoked = true }
    func readCount() -> Int { reads }
}

@Suite(.serialized) struct MCPHTTPLifecycleTests {
    private func wait(_ server: MCPLoopbackFixture, key: String, value: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await server.stats()[key] != value {
            guard ContinuousClock.now < deadline else { throw MCPClientError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func initialize(_ transport: MCPHTTPTransport, _ configuration: MCPServerConfiguration) async throws -> String {
        let reply = try await transport.send(configuration: configuration, method: "initialize", params: [:], id: 1, sessionID: nil)
        return try #require(reply.sessionID)
    }
    private func slow(_ transport: MCPHTTPTransport, _ configuration: MCPServerConfiguration, session: String) -> Task<MCPHTTPReply, Error> {
        Task { try await transport.send(configuration: configuration, method: "tools/call", params: [:], id: 37, sessionID: session) }
    }
    @Test func concurrentCancellationAndDisconnectUseOriginalIDAndFrozenBearerOnce() async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let secrets = RevocableSyntheticMCPSecret(), transport = MCPHTTPTransport(secrets: secrets)
        let configuration = server.configuration(path: "legacy/slow", version: .legacy20251125, secret: "synthetic-ref")
        let session = try await initialize(transport, configuration)
        let operation = slow(transport, configuration, session: session)
        try await wait(server, key: "slow_open")
        await secrets.revoke()
        operation.cancel()
        async let first: Void = transport.disconnect(configuration: configuration)
        async let second: Void = transport.disconnect(configuration: configuration)
        await #expect(throws: CancellationError.self) { try await operation.value }
        _ = await (first, second)
        try await wait(server, key: "slow_closed")
        let stats = try await server.stats(), diagnostics = await transport.diagnostics()
        #expect(stats["cancels"] == 1 && stats["cancel_request_id"] == 37 && stats["deletes"] == 1)
        #expect(stats["control_authorization_valid"] == 2 && stats["control_invalid"] == 0)
        #expect(await secrets.readCount() == 2)
        #expect(diagnostics.cancellationAccepted == 1 && diagnostics.sessionsDeleted == 1)
        #expect(diagnostics.activeOperations == 0 && diagnostics.retainedSessions == 0)
    }
    @Test func cancelledInitializationDeletesKnownSessionWithoutCancellationNotification() async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let transport = MCPHTTPTransport()
        let configuration = server.configuration(path: "legacy/init-slow", version: .legacy20251125)
        let operation = Task { try await initialize(transport, configuration) }
        try await wait(server, key: "init_headers")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await transport.diagnostics().retainedSessions != 1 {
            guard ContinuousClock.now < deadline else { operation.cancel(); throw MCPClientError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        await transport.disconnect(configuration: configuration)
        await #expect(throws: CancellationError.self) { try await operation.value }
        let stats = try await server.stats(), diagnostics = await transport.diagnostics()
        #expect(stats["initializes"] == 1 && stats["cancels"] == 0 && stats["deletes"] == 1)
        #expect(diagnostics.initializationUnconfirmed == 0 && diagnostics.sessionsDeleted == 1)
        #expect(diagnostics.activeOperations == 0 && diagnostics.retainedSessions == 0)
    }
    @Test func initializationWithoutSessionHeaderReportsUnknownCleanupWithoutForbiddenCancel() async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let transport = MCPHTTPTransport()
        let configuration = server.configuration(path: "legacy/init-noheaders", version: .legacy20251125, timeout: 1)
        await #expect(throws: MCPClientError.timeout) { try await initialize(transport, configuration) }
        await transport.disconnect(configuration: configuration)
        let stats = try await server.stats(), diagnostics = await transport.diagnostics()
        #expect(stats["initializes"] == 1 && stats["cancels"] == 0 && stats["deletes"] == 0)
        #expect(diagnostics.initializationUnconfirmed == 1)
        #expect(diagnostics.activeOperations == 0 && diagnostics.retainedSessions == 0)
    }
    @Test func explicitDisconnectDuringRefreshPreventsSecondInitialize() async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let transport = MCPHTTPTransport()
        let configuration = server.configuration(path: "legacy/delete-gate", version: .legacy20251125)
        _ = try await initialize(transport, configuration)
        let refresh = Task { try await initialize(transport, configuration) }
        try await wait(server, key: "delete_open")
        // 先直接进入disconnect；独立释放方稍后放行服务端DELETE，调用方不取消refresh。
        let releaseURL = server.baseURL.appendingPathComponent("release-delete")
        let release = Task {
            try await Task.sleep(for: .milliseconds(300))
            _ = try await URLSession.shared.data(from: releaseURL)
        }
        await transport.disconnect(configuration: configuration)
        try await release.value
        await #expect(throws: MCPClientError.invalidated) { try await refresh.value }
        let stats = try await server.stats(), diagnostics = await transport.diagnostics()
        #expect(stats["initializes"] == 1 && stats["deletes"] == 1)
        #expect(diagnostics.activeOperations == 0 && diagnostics.retainedSessions == 0)
        // 老revision的迟到断开不应撤销新revision。
        let replacement = MCPServerConfiguration(id: configuration.id, name: configuration.name,
            endpoint: configuration.endpoint, allowsLocalHTTP: true, enabled: true, protocolVersion: .legacy20251125)
        _ = try await initialize(transport, replacement)
        await transport.disconnect(configuration: configuration)
        #expect(await transport.diagnostics().retainedSessions == 1)
        await transport.disconnect(configuration: replacement)
        #expect(await transport.diagnostics().retainedSessions == 0)
    }
    @Test(arguments: ["delete-405", "delete-404", "delete-fail", "delete-redirect"])
    func sessionCleanupOutcomesRemainExplicitAndDoNotRedirect(path: String) async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let transport = MCPHTTPTransport()
        let configuration = server.configuration(path: "legacy/" + path, version: .legacy20251125)
        _ = try await initialize(transport, configuration)
        await transport.disconnect(configuration: configuration)
        let stats = try await server.stats(), diagnostics = await transport.diagnostics()
        #expect(stats["deletes"] == 1 && stats["redirect_hits"] == 0 && stats["control_invalid"] == 0)
        #expect(diagnostics.sessionDeleteUnsupported == (path == "delete-405" ? 1 : 0))
        #expect(diagnostics.sessionsAlreadyGone == (path == "delete-404" ? 1 : 0))
        #expect(diagnostics.sessionDeleteUnconfirmed == (["delete-fail", "delete-redirect"].contains(path) ? 1 : 0))
        #expect(diagnostics.activeOperations == 0 && diagnostics.retainedSessions == 0)
    }
    @Test(arguments: ["control-timeout", "cancel-redirect"])
    func failedControlKeepsOriginalCancellationAndReleasesOwnedState(path: String) async throws {
        let server = try MCPLoopbackFixture(); defer { server.stop() }
        let transport = MCPHTTPTransport()
        let configuration = server.configuration(path: "legacy/" + path, version: .legacy20251125, timeout: 1)
        let session = try await initialize(transport, configuration)
        let operation = slow(transport, configuration, session: session)
        try await wait(server, key: "slow_open")
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await transport.disconnect(configuration: configuration)
        let stats = try await server.stats(), diagnostics = await transport.diagnostics()
        #expect(stats["cancels"] == 1 && stats["cancel_request_id"] == 37 && stats["redirect_hits"] == 0)
        #expect(diagnostics.cancellationUnconfirmed == 1)
        #expect(diagnostics.sessionDeleteUnconfirmed == (path == "control-timeout" ? 1 : 0))
        #expect(diagnostics.activeOperations == 0 && diagnostics.retainedSessions == 0)
    }
}
