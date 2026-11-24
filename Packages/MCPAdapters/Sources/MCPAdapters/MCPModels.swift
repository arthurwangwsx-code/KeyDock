import Foundation
import AICore

/// 两代协议显式选择；旧握手不能被误标为当前无状态协议。
public enum MCPProtocolVersion: String, Codable, CaseIterable, Sendable {
    case modern20260728 = "2026-07-28"
    case legacy20251125 = "2025-11-25"
}

public enum MCPTransportKind: String, Codable, Sendable { case http, stdio }

public struct MCPServerConfiguration: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let endpoint: URL
    public let transportKind: MCPTransportKind
    public let stdioLaunch: MCPStdioLaunchConfiguration?
    public let allowsLocalHTTP: Bool
    public let enabled: Bool
    public let protocolVersion: MCPProtocolVersion
    /// 配置每次保存生成新revision；模型无法选择或变更连接目标。
    public let revision: UUID
    public let secretReference: String?
    public let timeoutSeconds: TimeInterval

    public init(id: UUID = UUID(), name: String, endpoint: URL, allowsLocalHTTP: Bool = false,
                enabled: Bool = false, protocolVersion: MCPProtocolVersion = .modern20260728,
                revision: UUID = UUID(), secretReference: String? = nil, timeoutSeconds: TimeInterval = 30) {
        self.id = id; self.name = name; self.endpoint = endpoint
        self.transportKind = .http; self.stdioLaunch = nil
        self.allowsLocalHTTP = allowsLocalHTTP; self.enabled = enabled
        self.protocolVersion = protocolVersion; self.revision = revision
        self.secretReference = secretReference; self.timeoutSeconds = timeoutSeconds
    }
    public init(id: UUID = UUID(), name: String, stdio: MCPStdioLaunchConfiguration,
                enabled: Bool = false, protocolVersion: MCPProtocolVersion = .modern20260728,
                revision: UUID = UUID(), timeoutSeconds: TimeInterval = 30) {
        self.id = id; self.name = name; self.endpoint = URL(fileURLWithPath: stdio.executable)
        self.transportKind = .stdio; self.stdioLaunch = stdio
        self.allowsLocalHTTP = false; self.enabled = enabled
        self.protocolVersion = protocolVersion; self.revision = revision
        self.secretReference = nil; self.timeoutSeconds = timeoutSeconds
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, transportKind, stdioLaunch, allowsLocalHTTP, enabled
        case protocolVersion, revision, secretReference, timeoutSeconds
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        endpoint = try fields.decode(URL.self, forKey: .endpoint)
        transportKind = try fields.decodeIfPresent(MCPTransportKind.self, forKey: .transportKind) ?? .http
        stdioLaunch = try fields.decodeIfPresent(MCPStdioLaunchConfiguration.self, forKey: .stdioLaunch)
        allowsLocalHTTP = try fields.decode(Bool.self, forKey: .allowsLocalHTTP)
        enabled = try fields.decode(Bool.self, forKey: .enabled)
        protocolVersion = try fields.decode(MCPProtocolVersion.self, forKey: .protocolVersion)
        revision = try fields.decode(UUID.self, forKey: .revision)
        secretReference = try fields.decodeIfPresent(String.self, forKey: .secretReference)
        timeoutSeconds = try fields.decode(TimeInterval.self, forKey: .timeoutSeconds)
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              timeoutSeconds.isFinite, (1...120).contains(timeoutSeconds) else { throw MCPClientError.invalidConfiguration }
        if transportKind == .stdio {
            guard let stdioLaunch, endpoint.isFileURL, endpoint.path == stdioLaunch.executable,
                  secretReference == nil, !allowsLocalHTTP else { throw MCPClientError.invalidConfiguration }
            try stdioLaunch.validate()
            return
        }
        guard stdioLaunch == nil else { throw MCPClientError.invalidConfiguration }
        let host = endpoint.host?.lowercased() ?? ""
        let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !host.isEmpty, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.scheme?.lowercased() == "https" ||
                (endpoint.scheme?.lowercased() == "http" && allowsLocalHTTP && loopback),
              timeoutSeconds.isFinite, (1...120).contains(timeoutSeconds),
              secretReference.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
            throw MCPClientError.invalidConfiguration
        }
    }
}

/// 凭据由宿主按固定来源读取；不持久化在连接配置或模型参数中。
public protocol MCPSecretProviding: Sendable {
    func bearerToken(serverID: UUID, reference: String) async throws -> String?
}
public struct NoMCPSecrets: MCPSecretProviding {
    public init() {}
    public func bearerToken(serverID: UUID, reference: String) async throws -> String? { nil }
}

public enum MCPClientError: Error, Equatable, Sendable {
    case invalidConfiguration, disabled, busy, invalidated, timeout, transport
    case httpStatus(Int), invalidResponse, protocolMismatch, remoteError(Int)
    case unsupportedServerRequest, unsupportedSchema, invalidTool, duplicateTool
    case limitExceeded, catalogChanged, unknownTool, invalidArguments, unsupportedContent
    case interactiveResultUnsupported, missingCredential, processExited, unsupportedCapability, selectionRequired
}

public struct MCPToolDescriptor: Equatable, Sendable, Identifiable {
    public var id: String { definition.name }
    public let originalName: String
    public let definition: AIToolDefinition
    /// 服务端声明只能用于展示，不能产生只读授权。
    public let untrustedReadOnlyHint: Bool?
}
public struct MCPRejectedTool: Equatable, Sendable {
    public let originalName: String
    public let reason: MCPClientError
}
public struct MCPToolCatalog: Equatable, Sendable {
    public let serverID: UUID
    public let configurationRevision: UUID
    public let revision: String
    public let tools: [MCPToolDescriptor]
    public let rejectedTools: [MCPRejectedTool]
}
public struct MCPToolResult: Equatable, Sendable {
    public let text: String
    public let structuredContent: JSONValue?
    public let isError: Bool
}

public struct MCPHTTPReply: Sendable {
    public let result: [String: JSONValue]
    public let sessionID: String?
    public let catalogChanged: Bool
    public init(result: [String: JSONValue], sessionID: String? = nil, catalogChanged: Bool = false) {
        self.result = result; self.sessionID = sessionID; self.catalogChanged = catalogChanged
    }
}
public protocol MCPHTTPTransporting: Sendable {
    func send(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue],
              id: Int?, sessionID: String?) async throws -> MCPHTTPReply
    func disconnect(configuration: MCPServerConfiguration) async
}
public extension MCPHTTPTransporting {
    func disconnect(configuration: MCPServerConfiguration) async {}
}
