import Foundation
import AICore

private final class MCPNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 同源重定向也不跟随；不会将Bearer或会话头投送到另一个请求地址。
        completionHandler(nil)
    }
}

/// 独立的有界HTTP工具路径，不承担OAuth、采样、elicitation、资源订阅或后台重连。
public struct MCPHTTPTransport: MCPHTTPTransporting {
    private let secrets: any MCPSecretProviding
    public init(secrets: any MCPSecretProviding = NoMCPSecrets()) { self.secrets = secrets }

    public func send(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue],
                     id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
        try configuration.validate()
        guard configuration.transportKind == .http else { throw MCPClientError.invalidConfiguration }
        guard configuration.enabled else { throw MCPClientError.disabled }
        do {
            return try await withThrowingTaskGroup(of: MCPHTTPReply.self) { group in
                group.addTask { try await perform(configuration: configuration, method: method, params: params, id: id, sessionID: sessionID) }
                group.addTask {
                    try await Task.sleep(for: .seconds(configuration.timeoutSeconds))
                    throw MCPClientError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as MCPClientError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw MCPClientError.timeout }
        catch { throw MCPClientError.transport }
    }

    private func perform(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue],
                         id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
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
        try Task.checkCancellation()
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = configuration.timeoutSeconds
        options.timeoutIntervalForResource = configuration.timeoutSeconds
        options.httpShouldSetCookies = false; options.httpCookieStorage = nil
        options.urlCache = nil; options.urlCredentialStorage = nil
        let session = URLSession(configuration: options, delegate: MCPNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw MCPClientError.httpStatus(http.statusCode) }
        let returnedSession = modern ? nil : http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if let returnedSession, !Self.validSessionID(returnedSession) { throw MCPClientError.invalidResponse }
        var count = 0
        if id == nil {
            guard http.statusCode == 202 else { throw MCPClientError.invalidResponse }
            for try await _ in bytes {
                try Task.checkCancellation()
                throw MCPClientError.invalidResponse
            }
            return MCPHTTPReply(result: [:], sessionID: returnedSession)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard mime == "application/json" || mime == "text/event-stream" else { throw MCPClientError.invalidResponse }
        var decoder = MCPWireDecoder(id: id!, modern: modern)
        var json = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); count += 1
            guard count <= 1_048_576 else { throw MCPClientError.limitExceeded }
            if mime == "text/event-stream" {
                if let result = try decoder.consume(byte) {
                    return MCPHTTPReply(result: result, sessionID: returnedSession, catalogChanged: decoder.catalogChanged)
                }
            } else { json.append(byte) }
        }
        if mime == "application/json", let result = try decoder.parse(json) {
            return MCPHTTPReply(result: result, sessionID: returnedSession, catalogChanged: decoder.catalogChanged)
        }
        throw MCPClientError.invalidResponse
    }
    private static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

/// SSE按字节收口再解码UTF-8；不把分片多字节字符损坏成替换符。
private struct MCPWireDecoder {
    let id: Int
    let modern: Bool
    var catalogChanged = false
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
            throw MCPClientError.remoteError(Int(code))
        }
        guard let result = object["result"]?.objectValue else { throw MCPClientError.invalidResponse }
        if modern {
            if result["resultType"] == .string("input_required") { throw MCPClientError.interactiveResultUnsupported }
            guard result["resultType"] == .string("complete") else { throw MCPClientError.invalidResponse }
        }
        return result
    }
}
