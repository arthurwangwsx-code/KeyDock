import Foundation
import AICore

/// newline JSON-RPC通道。request取消发协议通知，不把远端副作用声称为已撤回。
public actor MCPStdioTransport: MCPHTTPTransporting {
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<MCPHTTPReply, Error>
        let timeout: Task<Void, Never>
        var write: Task<Void, Never>?
    }
    private let configuration: MCPServerConfiguration
    private var process: MCPStdioProcess?
    private var reader: Task<Void, Never>?
    private var closing: Task<MCPProcessDiagnostics, Never>?
    private var pending: [Int: Pending] = [:]
    private var generation = UUID()
    private var launchEpoch = UUID()
    private var retired: [Int] = []
    private var catalogChanged = false
    private var lastDiagnostics = MCPProcessDiagnostics(stderrBytesDiscarded: 0, exited: true, forcedTermination: false)

    public init(configuration: MCPServerConfiguration) throws {
        try configuration.validate()
        guard configuration.transportKind == .stdio else { throw MCPClientError.invalidConfiguration }
        self.configuration = configuration
    }
    public func send(configuration supplied: MCPServerConfiguration, method: String, params: [String: JSONValue], id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
        try Task.checkCancellation()
        guard supplied == configuration, sessionID == nil else { throw MCPClientError.invalidConfiguration }
        guard configuration.enabled else { throw MCPClientError.disabled }
        let epoch = launchEpoch
        let discovery = method == "initialize" || method == "server/discover"
        if method == "initialize", process != nil {
            guard pending.isEmpty else { throw MCPClientError.busy }
            await close(error: MCPClientError.invalidated)
        }
        if let closing { _ = await closing.value }
        try Task.checkCancellation()
        guard launchEpoch == epoch else { throw MCPClientError.invalidated }
        if process == nil {
            guard discovery, let launch = configuration.stdioLaunch else { throw MCPClientError.protocolMismatch }
            try start(launch)
        }
        guard let process else { throw MCPClientError.processExited }
        if discovery { catalogChanged = false }
        guard !catalogChanged else { throw MCPClientError.catalogChanged }
        let token = generation
        let frame = try encode(method: method, params: params, id: id)
        if id == nil {
            try await process.write(frame, timeout: configuration.timeoutSeconds)
            try Task.checkCancellation()
            guard generation == token else { throw MCPClientError.invalidated }
            return .init(result: [:])
        }
        let id = id!
        guard pending.count < 32, pending[id] == nil else { throw MCPClientError.busy }
        let timeoutSeconds = configuration.timeoutSeconds
        return try await withTaskCancellationHandler(operation: {
            let reply: MCPHTTPReply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPHTTPReply, Error>) in
                let timeout = Task<Void, Never> { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
                    catch { return }
                    await self?.cancelRequest(id, token: token, error: MCPClientError.timeout)
                }
                pending[id] = Pending(method: method, continuation: continuation, timeout: timeout, write: nil)
                let write = Task<Void, Never> { [weak self] in
                    do { try await process.write(frame, timeout: timeoutSeconds) }
                    catch { await self?.writeFailed(id, token: token, error: error) }
                }
                pending[id]?.write = write
            }
            try Task.checkCancellation()
            return reply
        }, onCancel: { Task { await self.cancelRequest(id, token: token, error: CancellationError()) } })
    }
    public func disconnect(configuration supplied: MCPServerConfiguration) async {
        guard supplied.id == configuration.id, supplied.revision == configuration.revision else { return }
        launchEpoch = UUID()
        await close(error: CancellationError())
    }
    public func diagnostics() -> MCPProcessDiagnostics { process?.diagnostics() ?? lastDiagnostics }

    private func start(_ launch: MCPStdioLaunchConfiguration) throws {
        let child = try MCPStdioProcess(launch)
        generation = UUID(); retired = []; catalogChanged = false; process = child
        let token = generation, lines = child.incomingLines
        reader = Task { [weak self] in
            do {
                for try await line in lines {
                    try Task.checkCancellation()
                    await self?.receive(line, token: token)
                }
                await self?.readerEnded(token: token, error: MCPClientError.processExited)
            } catch { await self?.readerEnded(token: token, error: error) }
        }
    }
    private func receive(_ line: Data, token: UUID) async {
        guard token == generation else { return }
        do {
            guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: line),
                  object["jsonrpc"] == .string("2.0") else { throw MCPClientError.invalidResponse }
            if let method = object["method"]?.stringValue {
                guard object["id"] == nil else { throw MCPClientError.unsupportedServerRequest }
                if ["notifications/tools/list_changed", "notifications/resources/list_changed", "notifications/prompts/list_changed"].contains(method) {
                    catalogChanged = true
                }
                return
            }
            guard let raw = object["id"]?.numberValue, raw.rounded() == raw, abs(raw) < 9_007_199_254_740_991 else {
                throw MCPClientError.invalidResponse
            }
            let id = Int(raw)
            guard pending[id] != nil else {
                if retired.contains(id) { return }
                throw MCPClientError.invalidResponse
            }
            guard (object["result"] != nil) != (object["error"] != nil) else { throw MCPClientError.invalidResponse }
            if let error = object["error"]?.objectValue {
                guard let code = error["code"]?.numberValue, code.rounded() == code, abs(code) < 9_007_199_254_740_991 else {
                    throw MCPClientError.invalidResponse
                }
                finish(id, result: .failure(MCPClientError.remoteError(Int(code))))
                return
            }
            guard let result = object["result"]?.objectValue else { throw MCPClientError.invalidResponse }
            if configuration.protocolVersion == .modern20260728 {
                if result["resultType"] == .string("input_required") {
                    finish(id, result: .failure(MCPClientError.interactiveResultUnsupported)); return
                }
                guard result["resultType"] == .string("complete") else { throw MCPClientError.invalidResponse }
            }
            finish(id, result: .success(.init(result: result, catalogChanged: catalogChanged)))
        } catch { await close(error: error) }
    }
    private func writeFailed(_ id: Int, token: UUID, error: Error) async {
        guard generation == token, pending[id] != nil else { return }
        await close(error: error)
    }
    private func cancelRequest(_ id: Int, token: UUID, error: Error) async {
        guard generation == token, let request = pending[id] else { return }
        if request.method == "initialize" || request.method == "server/discover" {
            await close(error: error); return
        }
        let notification: Task<Void, Never>?
        if let process, let frame = try? encode(method: "notifications/cancelled", params: ["requestId": .number(Double(id))], id: nil) {
            // 与当前timeout Task分开，finish取消计时器时仍能发送协议取消通知。
            notification = Task.detached { try? await process.write(frame, timeout: 1) }
        } else { notification = nil }
        finish(id, result: .failure(error))
        await notification?.value
    }
    private func readerEnded(token: UUID, error: Error) async {
        guard token == generation else { return }
        await close(error: error)
    }
    private func finish(_ id: Int, result: Result<MCPHTTPReply, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel(); request.write?.cancel()
        retired.append(id)
        if retired.count > 256 { retired.removeFirst(retired.count - 256) }
        request.continuation.resume(with: result)
    }
    private func close(error: Error) async {
        if let closing { lastDiagnostics = await closing.value; return }
        generation = UUID(); catalogChanged = true
        let child = process; process = nil
        reader?.cancel(); reader = nil
        let requests = pending; pending.removeAll()
        for request in requests.values {
            request.timeout.cancel(); request.write?.cancel()
            request.continuation.resume(throwing: error)
        }
        if let child {
            let operation = Task { await child.close() }
            closing = operation
            lastDiagnostics = await operation.value
            closing = nil
        }
    }
    private func encode(method: String, params: [String: JSONValue], id: Int?) throws -> Data {
        var params = params
        if configuration.protocolVersion == .modern20260728, id != nil {
            params["_meta"] = .object([
                "io.modelcontextprotocol/protocolVersion": .string(configuration.protocolVersion.rawValue),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
                "io.modelcontextprotocol/clientInfo": .object(["name": .string("KeyDock"), "version": .string("1")])
            ])
        }
        var payload: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]
        if let id { payload["id"] = .number(Double(id)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(payload)
        guard data.count < 262_144 else { throw MCPClientError.limitExceeded }
        data.append(10)
        return data
    }
}
