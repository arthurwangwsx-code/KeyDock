import Foundation
import AICore

final class MCPNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 同源重定向也不跟随；不会将Bearer或会话头投送到另一个请求地址。
        completionHandler(nil)
    }
}

/// 每个来源／revision拥有有界通道；具体网络和控制清理由本actor收口。
public actor MCPHTTPTransport: MCPHTTPTransporting {
    private struct Operation {
        let worker: Task<MCPHTTPReply,Error>
        let method: String
        let requestID: Int?
        let sessionID: String?
        var authorization: String?
        var dispatched = false
        var completed = false
    }
    private struct Lease { let operationID:UUID; let authorization:String? }
    private struct Channel {
        let configuration:MCPServerConfiguration
        let token = UUID()
        var operations: [UUID:Operation] = [:]
        var sessions: [String:Lease] = [:]
        var closing: Task<Void,Never>?
        var waiters: [CheckedContinuation<Void,Never>] = []
    }
    private let secrets: any MCPSecretProviding
    private var channels: [UUID:Channel] = [:]
    private var entryEpochs: [UUID:UUID] = [:]
    private var entryConfigurations: [UUID:MCPServerConfiguration] = [:]
    private var entryCounts: [UUID:Int] = [:]
    private var cleanup = MCPHTTPCleanupDiagnostics()
    public init(secrets: any MCPSecretProviding = NoMCPSecrets()) { self.secrets = secrets }

    public func send(configuration:MCPServerConfiguration,method:String,params:[String:JSONValue],id:Int?,sessionID:String?) async throws -> MCPHTTPReply {
        try Task.checkCancellation(); try configuration.validate()
        guard configuration.transportKind == .http else { throw MCPClientError.invalidConfiguration }
        guard configuration.enabled else { throw MCPClientError.disabled }
        if entryCounts[configuration.id] == nil, entryEpochs[configuration.id] == nil {
            guard entryEpochs.count < 16 else { throw MCPClientError.busy }
            entryEpochs[configuration.id] = UUID()
            entryConfigurations[configuration.id] = configuration
        }
        guard entryConfigurations[configuration.id] == configuration else { throw MCPClientError.invalidated }
        let entryEpoch = entryEpochs[configuration.id]!
        entryCounts[configuration.id,default:0] += 1
        defer { finishEntry(configuration.id) }
        if let existing = channels[configuration.id] {
            guard existing.configuration == configuration, existing.closing == nil else { throw MCPClientError.invalidated }
            if method == "initialize" {
                guard existing.operations.isEmpty else { throw MCPClientError.busy }
                await retireChannel(configuration:configuration)
                try Task.checkCancellation()
                guard entryEpochs[configuration.id] == entryEpoch else { throw MCPClientError.invalidated }
            }
        }
        if channels[configuration.id] == nil {
            guard channels.count < 16 else { throw MCPClientError.busy }
            channels[configuration.id] = Channel(configuration:configuration)
        }
        guard let channel = channels[configuration.id], channel.configuration == configuration, channel.closing == nil,
              channel.operations.count < 32 else { throw MCPClientError.busy }
        let token = channel.token, operationID = UUID()
        let worker = Task { try await self.boundedPerform(configuration:configuration,method:method,params:params,id:id,sessionID:sessionID,channelToken:token,operationID:operationID) }
        channels[configuration.id]?.operations[operationID] = Operation(worker:worker,method:method,requestID:id,sessionID:sessionID)
        defer { finishOperation(configuration,token:token,id:operationID) }
        do {
            let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard channels[configuration.id]?.token == token, channels[configuration.id]?.closing == nil else { throw MCPClientError.invalidated }
            return value
        } catch {
            let error = normalized(error)
            if configuration.protocolVersion == .legacy20251125,
               let operation = channels[configuration.id]?.operations[operationID] {
                if method == "initialize" {
                    // initialize不得发取消通知；已知session即使正文失败也需清理。
                    let leases = channels[configuration.id]?.sessions.filter { $0.value.operationID == operationID } ?? [:]
                    if leases.isEmpty, operation.dispatched, !operation.completed,
                       error is CancellationError || (error as? MCPClientError) == .timeout { cleanup.initializationUnconfirmed += 1 }
                    for (session,lease) in leases {
                        await control(.init(configuration:configuration,sessionID:session,authorization:lease.authorization),kind:.delete)
                        if channels[configuration.id]?.token == token { channels[configuration.id]?.sessions[session] = nil }
                    }
                } else if (error is CancellationError || (error as? MCPClientError) == .timeout),
                          operation.dispatched, !operation.completed, let requestID = id {
                    await control(.init(configuration:configuration,sessionID:operation.sessionID,authorization:operation.authorization),kind:.cancel(requestID))
                }
            }
            throw error
        }
    }
    private func normalized(_ error:Error) -> Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if let error = error as? MCPClientError { return error }
        if (error as? URLError)?.code == .timedOut { return MCPClientError.timeout }
        return MCPClientError.transport
    }
    private func boundedPerform(configuration:MCPServerConfiguration,method:String,params:[String:JSONValue],id:Int?,sessionID:String?,channelToken:UUID,operationID:UUID) async throws -> MCPHTTPReply {
        try await withThrowingTaskGroup(of:MCPHTTPReply.self) { group in
            group.addTask { try await self.perform(configuration:configuration,method:method,params:params,id:id,sessionID:sessionID,channelToken:channelToken,operationID:operationID) }
            group.addTask { try await Task.sleep(for:.seconds(configuration.timeoutSeconds)); throw MCPClientError.timeout }
            defer { group.cancelAll() }; return try await group.next()!
        }
    }
    public func disconnect(configuration:MCPServerConfiguration) async {
        guard entryConfigurations[configuration.id] == configuration else { return }
        if entryEpochs[configuration.id] != nil { entryEpochs[configuration.id] = UUID() }
        await retireChannel(configuration:configuration)
    }
    private func retireChannel(configuration:MCPServerConfiguration) async {
        guard let channel = channels[configuration.id], channel.configuration == configuration else { return }
        if let closing = channel.closing { await closing.value; return }
        let token = channel.token
        let closing = Task { await self.closeChannel(configuration,token:token) }
        channels[configuration.id]?.closing = closing
        await closing.value
    }
    private func closeChannel(_ configuration:MCPServerConfiguration,token:UUID) async {
        guard let channel = channels[configuration.id], channel.token == token else { return }
        let workers = channel.operations.values.map(\.worker)
        workers.forEach { $0.cancel() }
        for worker in workers { _ = await worker.result }
        if channels[configuration.id]?.operations.isEmpty == false {
            await withCheckedContinuation { channels[configuration.id]?.waiters.append($0) }
        }
        // active移除前已完成自己的取消控制；不会反向等待closing，避免循环等待。
        guard let current = channels[configuration.id], current.token == token else { return }
        for (session,lease) in current.sessions {
            await control(.init(configuration:configuration,sessionID:session,authorization:lease.authorization),kind:.delete)
        }
        if channels[configuration.id]?.token == token {
            channels[configuration.id] = nil
            if entryCounts[configuration.id] == nil { entryEpochs[configuration.id] = nil; entryConfigurations[configuration.id] = nil }
        }
    }
    private func finishEntry(_ id:UUID) {
        guard let count = entryCounts[id] else { return }
        if count > 1 { entryCounts[id] = count-1 }
        else { entryCounts[id] = nil; if channels[id] == nil { entryEpochs[id] = nil; entryConfigurations[id] = nil } }
    }
    private func finishOperation(_ configuration:MCPServerConfiguration,token:UUID,id:UUID) {
        guard channels[configuration.id]?.token == token else { return }
        channels[configuration.id]?.operations[id] = nil
        if channels[configuration.id]?.operations.isEmpty == true {
            let waiters = channels[configuration.id]?.waiters ?? []; channels[configuration.id]?.waiters = []
            waiters.forEach { $0.resume() }
            if channels[configuration.id]?.closing == nil, channels[configuration.id]?.sessions.isEmpty == true { channels[configuration.id] = nil }
        }
    }
    private func recordAuthorization(_ configuration:MCPServerConfiguration,token:UUID,operationID:UUID,value:String?) {
        guard channels[configuration.id]?.token == token else { return }
        channels[configuration.id]?.operations[operationID]?.authorization = value
    }
    private func recordDispatched(_ configuration:MCPServerConfiguration,token:UUID,operationID:UUID) {
        guard channels[configuration.id]?.token == token else { return }
        channels[configuration.id]?.operations[operationID]?.dispatched = true
    }
    private func recordCompleted(_ configuration:MCPServerConfiguration,token:UUID,operationID:UUID) {
        guard channels[configuration.id]?.token == token else { return }
        channels[configuration.id]?.operations[operationID]?.completed = true
    }
    private func recordSession(_ configuration:MCPServerConfiguration,token:UUID,operationID:UUID,id:String) {
        guard channels[configuration.id]?.token == token else { return }
        let authorization = channels[configuration.id]?.operations[operationID]?.authorization
        channels[configuration.id]?.sessions[id] = Lease(operationID:operationID,authorization:authorization)
    }
    private func control(_ context:MCPHTTPControlContext,kind:MCPHTTPControlKind) async {
        // 私有控制任务不继承已取消的调用方状态；只复用原来源认证，无重定向、重试或工具派发。
        let outcome = await Task.detached { await MCPHTTPControl.send(context,kind:kind) }.value
        switch kind {
        case .cancel:
            if case .accepted = outcome { cleanup.cancellationAccepted += 1 } else { cleanup.cancellationUnconfirmed += 1 }
        case .delete:
            switch outcome {
            case .accepted: cleanup.sessionsDeleted += 1
            case .gone: cleanup.sessionsAlreadyGone += 1
            case .unsupported: cleanup.sessionDeleteUnsupported += 1
            case .unconfirmed: cleanup.sessionDeleteUnconfirmed += 1
            }
        }
    }
    public func diagnostics() -> MCPHTTPCleanupDiagnostics {
        var value = cleanup
        value.activeOperations = channels.values.reduce(0) { $0+$1.operations.count }
        value.retainedSessions = channels.values.reduce(0) { $0+$1.sessions.count }
        return value
    }
    private func perform(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue],
                         id: Int?, sessionID: String?, channelToken: UUID, operationID: UUID) async throws -> MCPHTTPReply {
        try Task.checkCancellation()
        var parameters = params
        let modern = configuration.protocolVersion == .modern20260728
        if modern {
            parameters["_meta"] = .object([
                "io.modelcontextprotocol/protocolVersion": .string(configuration.protocolVersion.rawValue),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
                "io.modelcontextprotocol/clientInfo": .object(["name": .string("KeyDock"), "version": .string("1")])
            ])
        }
        var envelope: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(parameters)]
        if let id { envelope["id"] = .number(Double(id)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(envelope)
        guard body.count <= 262_144 else { throw MCPClientError.limitExceeded }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"; request.httpBody = body
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if modern || method != "initialize" {
            request.setValue(configuration.protocolVersion.rawValue, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if modern {
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            let name = method == "resources/read" ? params["uri"]?.stringValue : params["name"]?.stringValue
            if ["tools/call", "resources/read", "prompts/get"].contains(method), let name {
                request.setValue(MCPHeaderValue.encode(name), forHTTPHeaderField: "Mcp-Name")
            }
        } else if let sessionID {
            guard Self.validSessionID(sessionID) else { throw MCPClientError.invalidResponse }
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let reference = configuration.secretReference {
            guard let token = try await secrets.bearerToken(serverID: configuration.id, reference: reference),
                  !token.isEmpty, token.utf8.count <= 8192,
                  token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw MCPClientError.missingCredential }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        recordAuthorization(configuration,token:channelToken,operationID:operationID,value:request.value(forHTTPHeaderField:"Authorization"))
        try Task.checkCancellation()
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = configuration.timeoutSeconds
        options.timeoutIntervalForResource = configuration.timeoutSeconds
        options.httpShouldSetCookies = false; options.httpCookieStorage = nil
        options.urlCache = nil; options.urlCredentialStorage = nil
        let session = URLSession(configuration: options, delegate: MCPNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        recordDispatched(configuration,token:channelToken,operationID:operationID)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            recordCompleted(configuration,token:channelToken,operationID:operationID)
            throw MCPClientError.httpStatus(http.statusCode)
        }
        let returnedSession = modern ? nil : http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if let returnedSession, !Self.validSessionID(returnedSession) { throw MCPClientError.invalidResponse }
        if method == "initialize", let returnedSession {
            recordSession(configuration,token:channelToken,operationID:operationID,id:returnedSession)
        }
        var count = 0
        if id == nil {
            guard http.statusCode == 202 else { throw MCPClientError.invalidResponse }
            for try await _ in bytes {
                try Task.checkCancellation()
                throw MCPClientError.invalidResponse
            }
            recordCompleted(configuration,token:channelToken,operationID:operationID)
            return MCPHTTPReply(result: [:], sessionID: returnedSession)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard mime == "application/json" || mime == "text/event-stream" else { throw MCPClientError.invalidResponse }
        var decoder = MCPWireDecoder(id: id!, modern: modern)
        defer { if decoder.finalResponseReceived { recordCompleted(configuration,token:channelToken,operationID:operationID) } }
        var json = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); count += 1
            guard count <= 1_048_576 else { throw MCPClientError.limitExceeded }
            if mime == "text/event-stream" {
                if let result = try decoder.consume(byte) {
                    recordCompleted(configuration,token:channelToken,operationID:operationID)
                    return MCPHTTPReply(result: result, sessionID: returnedSession, catalogChanged: decoder.catalogChanged)
                }
            } else { json.append(byte) }
        }
        if mime == "application/json", let result = try decoder.parse(json) {
            recordCompleted(configuration,token:channelToken,operationID:operationID)
            return MCPHTTPReply(result: result, sessionID: returnedSession, catalogChanged: decoder.catalogChanged)
        }
        throw MCPClientError.invalidResponse
    }
    private static func validSessionID(_ value:String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

/// SSE按字节收口再解码UTF-8；不把分片多字节字符损坏成替换符。
private struct MCPWireDecoder {
    let id: Int
    let modern: Bool
    var catalogChanged = false
    var finalResponseReceived = false
    private var line = Data()
    private var dataLines: [String] = []
    init(id: Int, modern: Bool) { self.id = id; self.modern = modern }
    mutating func consume(_ byte: UInt8) throws -> [String: JSONValue]? {
        if byte != 10 {
            line.append(byte)
            guard line.count <= 262_144 else { throw MCPClientError.limitExceeded }
            return nil
        }
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { throw MCPClientError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let payload = Data(dataLines.joined(separator: "\n").utf8)
            dataLines.removeAll(keepingCapacity: true)
            return try parse(payload)
        }
        if text.hasPrefix("data:") {
            let suffix = text.dropFirst(5)
            dataLines.append(String(suffix.first == " " ? suffix.dropFirst() : suffix))
        }
        return nil
    }
    mutating func parse(_ data: Data) throws -> [String: JSONValue]? {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              object["jsonrpc"] == .string("2.0") else { throw MCPClientError.invalidResponse }
        if let method = object["method"]?.stringValue {
            guard object["id"] == nil else { throw MCPClientError.unsupportedServerRequest }
            if ["notifications/tools/list_changed", "notifications/resources/list_changed", "notifications/prompts/list_changed"].contains(method) { catalogChanged = true }
            return nil
        }
        guard object["id"] == .number(Double(id)),
              (object["result"] != nil) != (object["error"] != nil) else { throw MCPClientError.invalidResponse }
        if let error = object["error"]?.objectValue {
            guard let code = error["code"]?.numberValue, code.isFinite, code.rounded() == code,
                  abs(code) < 9_007_199_254_740_991 else { throw MCPClientError.invalidResponse }
            finalResponseReceived = true
            throw MCPClientError.remoteError(Int(code))
        }
        guard let result = object["result"]?.objectValue else { throw MCPClientError.invalidResponse }
        finalResponseReceived = true
        if modern {
            if result["resultType"] == .string("input_required") { throw MCPClientError.interactiveResultUnsupported }
            guard result["resultType"] == .string("complete") else { throw MCPClientError.invalidResponse }
        }
        return result
    }
}
