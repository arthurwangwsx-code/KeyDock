import Foundation
import AICore

/// 每个Client默认持有独立router；配置变化须由宿主invalidate旧Client后创建新实例。
public actor MCPTransportRouter: MCPHTTPTransporting {
    private struct Channel { let configuration: MCPServerConfiguration; let transport: MCPStdioTransport }
    private let http: any MCPHTTPTransporting
    private var channels: [UUID: Channel] = [:]
    public init(http: any MCPHTTPTransporting = MCPHTTPTransport()) { self.http = http }
    public func send(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue], id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
        try configuration.validate()
        guard configuration.enabled else { throw MCPClientError.disabled }
        if configuration.transportKind == .http {
            return try await http.send(configuration: configuration, method: method, params: params, id: id, sessionID: sessionID)
        }
        let channel: Channel
        if let existing = channels[configuration.id] {
            guard existing.configuration == configuration else { throw MCPClientError.invalidated }
            channel = existing
        } else {
            channel = Channel(configuration: configuration, transport: try MCPStdioTransport(configuration: configuration))
            channels[configuration.id] = channel
        }
        return try await channel.transport.send(configuration: configuration, method: method, params: params, id: id, sessionID: sessionID)
    }
    public func disconnect(configuration: MCPServerConfiguration) async {
        if configuration.transportKind == .http { await http.disconnect(configuration: configuration); return }
        guard let channel = channels[configuration.id], channel.configuration.revision == configuration.revision else { return }
        channels.removeValue(forKey: configuration.id)
        await channel.transport.disconnect(configuration: configuration)
    }
}
