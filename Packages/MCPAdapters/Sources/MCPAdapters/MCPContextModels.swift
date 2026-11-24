import Foundation

/// 由宿主的明确来源选择创建，不向模型暴露为可调工具参数。
public struct MCPExplicitSourceSelection: Equatable, Sendable {
    public let serverID: UUID
    public let configurationRevision: UUID
    public init(serverID: UUID, configurationRevision: UUID) {
        self.serverID = serverID; self.configurationRevision = configurationRevision
    }
}
public struct MCPResourceDescriptor: Equatable, Sendable, Identifiable {
    public var id: String { uri }
    public let uri: String
    public let name: String
    public let description: String
    public let mimeType: String?
}
public struct MCPResourceSelection: Equatable, Sendable {
    public let source: MCPExplicitSourceSelection
    public let catalogRevision: UUID
    public let uri: String
    fileprivate init(source: MCPExplicitSourceSelection, catalogRevision: UUID, uri: String) {
        self.source = source; self.catalogRevision = catalogRevision; self.uri = uri
    }
}
public struct MCPResourceCatalog: Equatable, Sendable {
    public let source: MCPExplicitSourceSelection
    public let revision: UUID
    public let resources: [MCPResourceDescriptor]
    public func select(uri: String) throws -> MCPResourceSelection {
        guard resources.contains(where: { $0.uri == uri }) else { throw MCPClientError.selectionRequired }
        return .init(source: source, catalogRevision: revision, uri: uri)
    }
}
public struct MCPResourceText: Equatable, Sendable {
    public let uri: String
    public let mimeType: String?
    public let text: String
}
public struct MCPResourceResult: Equatable, Sendable {
    public let source: MCPExplicitSourceSelection
    public let contents: [MCPResourceText]
}
public struct MCPPromptArgument: Equatable, Sendable, Identifiable {
    public let name: String
    public var id: String { name }
    public let description: String
    public let required: Bool
}
public struct MCPPromptDescriptor: Equatable, Sendable, Identifiable {
    public let name: String
    public var id: String { name }
    public let description: String
    public let arguments: [MCPPromptArgument]
}
public struct MCPPromptSelection: Equatable, Sendable {
    public let source: MCPExplicitSourceSelection
    public let catalogRevision: UUID
    public let name: String
    fileprivate init(source: MCPExplicitSourceSelection, catalogRevision: UUID, name: String) {
        self.source = source; self.catalogRevision = catalogRevision; self.name = name
    }
}
public struct MCPPromptCatalog: Equatable, Sendable {
    public let source: MCPExplicitSourceSelection
    public let revision: UUID
    public let prompts: [MCPPromptDescriptor]
    public func select(name: String) throws -> MCPPromptSelection {
        guard prompts.contains(where: { $0.name == name }) else { throw MCPClientError.selectionRequired }
        return .init(source: source, catalogRevision: revision, name: name)
    }
}
public struct MCPPromptTextMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let text: String
}
public struct MCPPromptResult: Equatable, Sendable {
    public let source: MCPExplicitSourceSelection
    public let description: String
    public let messages: [MCPPromptTextMessage]
}
