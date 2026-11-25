import Foundation
import AICore

/// 诊断只保留计数，绝不包含Bearer、session ID、参数或正文。
public struct MCPHTTPCleanupDiagnostics: Sendable, Equatable {
    public internal(set) var cancellationAccepted = 0
    public internal(set) var cancellationUnconfirmed = 0
    public internal(set) var sessionsDeleted = 0
    public internal(set) var sessionsAlreadyGone = 0
    public internal(set) var sessionDeleteUnsupported = 0
    public internal(set) var sessionDeleteUnconfirmed = 0
    public internal(set) var initializationUnconfirmed = 0
    public internal(set) var activeOperations = 0
    public internal(set) var retainedSessions = 0
}

struct MCPHTTPControlContext: Sendable {
    let configuration: MCPServerConfiguration
    let sessionID: String?
    /// 原请求精确来源的短生命周期内存快照；清理不得读取已撤权来源的新凭据。
    let authorization: String?
}
enum MCPHTTPControlKind: Sendable { case cancel(Int), delete }
enum MCPHTTPControlOutcome: Sendable { case accepted, gone, unsupported, unconfirmed }

enum MCPHTTPControl {
    static func send(_ context:MCPHTTPControlContext,kind:MCPHTTPControlKind) async -> MCPHTTPControlOutcome {
        let timeout = min(3,context.configuration.timeoutSeconds)
        var request = URLRequest(url:context.configuration.endpoint)
        request.timeoutInterval = timeout
        request.setValue("application/json, text/event-stream",forHTTPHeaderField:"Accept")
        request.setValue(MCPProtocolVersion.legacy20251125.rawValue,forHTTPHeaderField:"MCP-Protocol-Version")
        if let session = context.sessionID { request.setValue(session,forHTTPHeaderField:"Mcp-Session-Id") }
        if let authorization = context.authorization { request.setValue(authorization,forHTTPHeaderField:"Authorization") }
        switch kind {
        case .cancel(let id):
            request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            let value: [String:JSONValue] = ["jsonrpc":.string("2.0"),"method":.string("notifications/cancelled"),"params":.object(["requestId":.number(Double(id))])]
            request.httpBody = try? JSONEncoder().encode(value)
        case .delete: request.httpMethod = "DELETE"
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = timeout; settings.timeoutIntervalForResource = timeout
        settings.httpShouldSetCookies = false; settings.httpCookieStorage = nil
        settings.urlCache = nil; settings.urlCredentialStorage = nil
        let session = URLSession(configuration:settings,delegate:MCPNoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes,response) = try await session.bytes(for:request)
            guard let response = response as? HTTPURLResponse else { return .unconfirmed }
            switch kind {
            case .cancel: guard response.statusCode == 202 else { return .unconfirmed }
            case .delete:
                if response.statusCode == 404 { return .gone }
                if response.statusCode == 405 { return .unsupported }
                guard (200...299).contains(response.statusCode) else { return .unconfirmed }
            }
            var count = 0
            for try await _ in bytes {
                count += 1
                if case .cancel = kind { return .unconfirmed } // 202通知必须空正文。
                guard count <= 4096 else { return .unconfirmed }
            }
            return .accepted
        } catch { return .unconfirmed }
    }
}
