import Foundation
import CryptoKit
import AICore
import AgentCore

/// 连接只由宿主创建，工具调用只能引用已冻结目录中的模型名和参数。
/// 宿主仍须在调用前完成范围和用户授权；服务端annotations不产生本机权限。
public actor MCPHTTPClient {
    public nonisolated let configuration: MCPServerConfiguration
    private let transport: any MCPHTTPTransporting
    private var sessionID: String?
    private var capabilities: Set<String> = []
    private var resourceCatalog: MCPResourceCatalog?
    private var promptCatalog: MCPPromptCatalog?
    private var generation = UUID()
    private var nextID = 1
    private var operations: [UUID: Task<MCPHTTPReply, Error>] = [:]
    private var discovering = false
    private var activeCalls = 0
    private var cachedCatalog: MCPToolCatalog?

    public init(configuration: MCPServerConfiguration, transport: any MCPHTTPTransporting = MCPTransportRouter()) throws {
        try configuration.validate()
        self.configuration = configuration; self.transport = transport
    }

    public func invalidate() async {
        generation = UUID(); cachedCatalog = nil; sessionID = nil
        let tasks = Array(operations.values); operations.removeAll()
        tasks.forEach { $0.cancel() }
        capabilities = []; resourceCatalog = nil; promptCatalog = nil
        await transport.disconnect(configuration: configuration)
    }

    public func discover() async throws -> MCPToolCatalog {
        guard configuration.enabled else { throw MCPClientError.disabled }
        guard !discovering, activeCalls == 0 else { throw MCPClientError.busy }
        discovering = true; capabilities = []; resourceCatalog = nil; promptCatalog = nil; cachedCatalog = nil; sessionID = nil; generation = UUID()
        let token = generation
        let connectionBudget = configuration.transportKind == .stdio ? (configuration.stdioLaunch?.startupTimeoutSeconds ?? configuration.timeoutSeconds) : configuration.timeoutSeconds
        defer { discovering = false }
        return try await withThrowingTaskGroup(of: MCPToolCatalog.self) { group in
            group.addTask { try await self.loadCatalog(generation: token) }
            group.addTask {
                try await Task.sleep(for: .seconds(connectionBudget))
                throw MCPClientError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func loadCatalog(generation token: UUID) async throws -> MCPToolCatalog {
        if configuration.protocolVersion == .legacy20251125 {
            let reply = try await rpc("initialize", params: [
                "protocolVersion": .string(configuration.protocolVersion.rawValue),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("KeyDock"), "version": .string("1")])
            ], token: token)
            guard reply.result["protocolVersion"] == .string(configuration.protocolVersion.rawValue),
                  let advertised = reply.result["capabilities"]?.objectValue else {
                throw MCPClientError.protocolMismatch
            }
            try acceptCapabilities(advertised)
            sessionID = reply.sessionID
            _ = try await rpc("notifications/initialized", params: [:], token: token, notification: true)
        } else {
            let reply = try await rpc("server/discover", params: [:], token: token)
            guard reply.result["supportedVersions"]?.arrayValue?.contains(.string(configuration.protocolVersion.rawValue)) == true,
                  let advertised = reply.result["capabilities"]?.objectValue else {
                throw MCPClientError.protocolMismatch
            }
            try acceptCapabilities(advertised)
        }
        if !capabilities.contains("tools") { return try finishCatalog(token: token, tools: [], rejected: []) }
        var tools: [MCPToolDescriptor] = []
        var rejected: [MCPRejectedTool] = []
        var originalNames: Set<String> = [], modelNames: Set<String> = [], seenCursors: Set<String> = []
        var cursor: String?
        var catalogBytes = 0
        for page in 0..<16 {
            let reply = try await rpc("tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:], token: token)
            guard let rows = reply.result["tools"]?.arrayValue else { throw MCPClientError.invalidResponse }
            guard tools.count + rejected.count + rows.count <= 128 else { throw MCPClientError.limitExceeded }
            for row in rows {
                guard let object = row.objectValue, let name = object["name"]?.stringValue,
                      !name.isEmpty, name.utf8.count <= 128 else { throw MCPClientError.invalidTool }
                guard originalNames.insert(name).inserted else { throw MCPClientError.duplicateTool }
                guard name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
                    rejected.append(.init(originalName: name, reason: .invalidTool)); continue
                }
                guard let schema = object["inputSchema"]?.objectValue else {
                    rejected.append(.init(originalName: name, reason: .unsupportedSchema)); continue
                }
                let description = object["description"]?.stringValue ?? name
                let schemaBytes = try Self.encoded(schema).count
                guard schemaBytes <= 65_536, description.utf8.count <= 8192 else { throw MCPClientError.limitExceeded }
                catalogBytes += schemaBytes + description.utf8.count + name.utf8.count
                guard catalogBytes <= 262_144 else { throw MCPClientError.limitExceeded }
                do { try ToolJSONSchema.checkSchema(schema) }
                catch { rejected.append(.init(originalName: name, reason: .unsupportedSchema)); continue }
                let modelName = "mcp_" + String(configuration.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)) + "_" + String(Self.digest(Data(name.utf8)).prefix(16))
                guard modelNames.insert(modelName).inserted else { throw MCPClientError.duplicateTool }
                let hint: Bool?
                if case .bool(let value) = object["annotations"]?.objectValue?["readOnlyHint"] { hint = value }
                else { hint = nil }
                tools.append(.init(originalName: name, definition: .init(name: modelName, description: description, parameters: schema), untrustedReadOnlyHint: hint))
            }
            if let next = reply.result["nextCursor"] {
                guard let value = next.stringValue, !value.isEmpty, value.utf8.count <= 4096,
                      seenCursors.insert(value).inserted, page < 15 else { throw MCPClientError.invalidResponse }
                cursor = value
            } else {
                return try finishCatalog(token: token, tools: tools, rejected: rejected)
            }
        }
        throw MCPClientError.limitExceeded
    }

    public func call(modelToolName: String, arguments: [String: JSONValue], catalogRevision: String) async throws -> MCPToolResult {
        try Task.checkCancellation()
        guard configuration.enabled else { throw MCPClientError.disabled }
        guard !discovering else { throw MCPClientError.busy }
        guard let catalog = cachedCatalog, catalog.revision == catalogRevision else { throw MCPClientError.catalogChanged }
        guard let tool = catalog.tools.first(where: { $0.definition.name == modelToolName }) else { throw MCPClientError.unknownTool }
        do { try ToolJSONSchema.validate(.object(arguments), schema: tool.definition.parameters) }
        catch { throw MCPClientError.invalidArguments }
        guard try Self.encoded(arguments).count <= 65_536 else { throw MCPClientError.limitExceeded }
        let token = generation
        activeCalls += 1
        defer { activeCalls -= 1 }
        let reply = try await rpc("tools/call", params: ["name": .string(tool.originalName), "arguments": .object(arguments)], token: token)
        guard cachedCatalog?.revision == catalogRevision else { throw MCPClientError.catalogChanged }
        guard let blocks = reply.result["content"]?.arrayValue, blocks.count <= 64 else { throw MCPClientError.invalidResponse }
        var text: [String] = []; var bytes = 0
        for block in blocks {
            guard let object = block.objectValue, object["type"] == .string("text"), let value = object["text"]?.stringValue else {
                throw MCPClientError.unsupportedContent
            }
            bytes += value.utf8.count + 1
            guard bytes <= 65_536 else { throw MCPClientError.limitExceeded }
            text.append(value)
        }
        let structured = reply.result["structuredContent"]
        if let structured {
            guard structured.objectValue != nil else { throw MCPClientError.invalidResponse }
            bytes += try Self.encoded(structured).count
            guard bytes <= 65_536 else { throw MCPClientError.limitExceeded }
        }
        let isError: Bool
        if let error = reply.result["isError"] {
            guard case .bool(let value) = error else { throw MCPClientError.invalidResponse }; isError = value
        } else { isError = false }
        return MCPToolResult(text: text.joined(separator: "\n"), structuredContent: structured, isError: isError)
    }

    public func availableCapabilities() -> Set<String> { cachedCatalog == nil ? [] : capabilities }

    public func listResources(selection: MCPExplicitSourceSelection) async throws -> MCPResourceCatalog {
        try validateSelection(selection, capability: "resources")
        let token = generation; activeCalls += 1
        defer { activeCalls -= 1 }
        let rows = try await contextRows("resources/list", key: "resources", token: token)
        var resources: [MCPResourceDescriptor] = []; var seen: Set<String> = []
        for row in rows {
            guard let object = row.objectValue, let uri = object["uri"]?.stringValue,
                  !uri.isEmpty, uri.utf8.count <= 4096, let name = object["name"]?.stringValue,
                  !name.isEmpty, name.utf8.count <= 256, seen.insert(uri).inserted else { throw MCPClientError.invalidResponse }
            let description = object["description"]?.stringValue ?? ""
            let mimeType = object["mimeType"]?.stringValue
            guard description.utf8.count <= 8192, mimeType.map({ $0.utf8.count <= 128 }) ?? true else { throw MCPClientError.limitExceeded }
            resources.append(.init(uri: uri, name: name, description: description, mimeType: mimeType))
        }
        try ensure(token)
        let catalog = MCPResourceCatalog(source: selection, revision: UUID(), resources: resources)
        resourceCatalog = catalog
        return catalog
    }

    public func readResource(selection: MCPResourceSelection) async throws -> MCPResourceResult {
        try validateSelection(selection.source, capability: "resources")
        guard resourceCatalog?.revision == selection.catalogRevision,
              resourceCatalog?.resources.contains(where: { $0.uri == selection.uri }) == true else { throw MCPClientError.catalogChanged }
        let token = generation; activeCalls += 1
        defer { activeCalls -= 1 }
        let reply = try await rpc("resources/read", params: ["uri": .string(selection.uri)], token: token)
        guard resourceCatalog?.revision == selection.catalogRevision else { throw MCPClientError.catalogChanged }
        guard let rows = reply.result["contents"]?.arrayValue, rows.count <= 64 else { throw MCPClientError.invalidResponse }
        var texts: [MCPResourceText] = []; var bytes = 0
        for row in rows {
            guard let object = row.objectValue, object["uri"] == .string(selection.uri) else { throw MCPClientError.selectionRequired }
            guard let text = object["text"]?.stringValue, object["blob"] == nil else { throw MCPClientError.unsupportedContent }
            let mimeType = object["mimeType"]?.stringValue
            bytes += text.utf8.count
            guard bytes <= 65_536, mimeType.map({ $0.utf8.count <= 128 }) ?? true else { throw MCPClientError.limitExceeded }
            texts.append(.init(uri: selection.uri, mimeType: mimeType, text: text))
        }
        return .init(source: selection.source, contents: texts)
    }

    public func listPrompts(selection: MCPExplicitSourceSelection) async throws -> MCPPromptCatalog {
        try validateSelection(selection, capability: "prompts")
        let token = generation; activeCalls += 1
        defer { activeCalls -= 1 }
        let rows = try await contextRows("prompts/list", key: "prompts", token: token)
        var prompts: [MCPPromptDescriptor] = []; var seen: Set<String> = []
        for row in rows {
            guard let object = row.objectValue, let name = object["name"]?.stringValue,
                  !name.isEmpty, name.utf8.count <= 256, seen.insert(name).inserted else { throw MCPClientError.invalidResponse }
            let description = object["description"]?.stringValue ?? ""
            guard description.utf8.count <= 8192 else { throw MCPClientError.limitExceeded }
            let arguments = object["arguments"]?.arrayValue ?? []
            guard arguments.count <= 32 else { throw MCPClientError.limitExceeded }
            var params: [MCPPromptArgument] = []; var names: Set<String> = []
            for argument in arguments {
                guard let entry = argument.objectValue, let key = entry["name"]?.stringValue,
                      !key.isEmpty, key.utf8.count <= 128, names.insert(key).inserted else { throw MCPClientError.invalidResponse }
                let text = entry["description"]?.stringValue ?? ""
                guard text.utf8.count <= 4096 else { throw MCPClientError.limitExceeded }
                let required: Bool
                if let value = entry["required"] {
                    guard case .bool(let flag) = value else { throw MCPClientError.invalidResponse }; required = flag
                } else { required = false }
                params.append(.init(name: key, description: text, required: required))
            }
            prompts.append(.init(name: name, description: description, arguments: params))
        }
        try ensure(token)
        let catalog = MCPPromptCatalog(source: selection, revision: UUID(), prompts: prompts)
        promptCatalog = catalog
        return catalog
    }

    public func getPrompt(selection: MCPPromptSelection, arguments: [String: String]) async throws -> MCPPromptResult {
        try validateSelection(selection.source, capability: "prompts")
        guard promptCatalog?.revision == selection.catalogRevision,
              let prompt = promptCatalog?.prompts.first(where: { $0.name == selection.name }) else { throw MCPClientError.catalogChanged }
        try prompt.validateArguments(arguments)
        let token = generation; activeCalls += 1
        defer { activeCalls -= 1 }
        let reply = try await rpc("prompts/get", params: ["name": .string(selection.name),
            "arguments": .object(arguments.mapValues(JSONValue.string))], token: token)
        guard promptCatalog?.revision == selection.catalogRevision else { throw MCPClientError.catalogChanged }
        guard let rows = reply.result["messages"]?.arrayValue, rows.count <= 64 else { throw MCPClientError.invalidResponse }
        let description = reply.result["description"]?.stringValue ?? ""
        var bytes = description.utf8.count; var messages: [MCPPromptTextMessage] = []
        guard bytes <= 65_536 else { throw MCPClientError.limitExceeded }
        for row in rows {
            guard let message = row.objectValue, let rawRole = message["role"]?.stringValue,
                  let role = MCPPromptTextMessage.Role(rawValue: rawRole),
                  let content = message["content"]?.objectValue, content["type"] == .string("text"),
                  let text = content["text"]?.stringValue else { throw MCPClientError.unsupportedContent }
            bytes += text.utf8.count
            guard bytes <= 65_536 else { throw MCPClientError.limitExceeded }
            messages.append(.init(role: role, text: text))
        }
        return .init(source: selection.source, description: description, messages: messages)
    }

    private func validateSelection(_ selection: MCPExplicitSourceSelection, capability: String) throws {
        try Task.checkCancellation()
        guard configuration.enabled, selection.serverID == configuration.id,
              selection.configurationRevision == configuration.revision else { throw MCPClientError.selectionRequired }
        guard !discovering, cachedCatalog != nil else { throw MCPClientError.catalogChanged }
        guard capabilities.contains(capability) else { throw MCPClientError.unsupportedCapability }
    }
    private func contextRows(_ method: String, key: String, token: UUID) async throws -> [JSONValue] {
        var result: [JSONValue] = [], cursor: String?, seen: Set<String> = []
        var bytes = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.timeoutSeconds))
        for page in 0..<16 {
            guard ContinuousClock.now < deadline else { throw MCPClientError.timeout }
            let reply = try await rpc(method, params: cursor.map { ["cursor": .string($0)] } ?? [:], token: token)
            guard let rows = reply.result[key]?.arrayValue else { throw MCPClientError.invalidResponse }
            result += rows; bytes += try Self.encoded(rows).count
            guard result.count <= 256, bytes <= 262_144 else { throw MCPClientError.limitExceeded }
            if let next = reply.result["nextCursor"] {
                guard let value = next.stringValue, !value.isEmpty, value.utf8.count <= 4096,
                      seen.insert(value).inserted, page < 15 else { throw MCPClientError.invalidResponse }
                cursor = value
            } else { return result }
        }
        throw MCPClientError.limitExceeded
    }

    private func acceptCapabilities(_ advertised: [String: JSONValue]) throws {
        for name in ["tools", "resources", "prompts"] where advertised[name] != nil {
            guard advertised[name]?.objectValue != nil else { throw MCPClientError.protocolMismatch }
        }
        capabilities = Set(advertised.keys).intersection(["tools", "resources", "prompts"])
    }
    private func finishCatalog(token: UUID, tools: [MCPToolDescriptor], rejected: [MCPRejectedTool]) throws -> MCPToolCatalog {
        try Task.checkCancellation(); try ensure(token)
        let sorted = tools.sorted { $0.definition.name < $1.definition.name }
        let signature = sorted.map { ["name": JSONValue.string($0.originalName), "definition": .object([
            "name": .string($0.definition.name), "description": .string($0.definition.description), "parameters": .object($0.definition.parameters)
        ])] }
        let material: [String: JSONValue] = ["serverID": .string(configuration.id.uuidString),
            "configurationRevision": .string(configuration.revision.uuidString), "generation": .string(token.uuidString),
            "tools": .array(signature.map(JSONValue.object))]
        let catalog = MCPToolCatalog(serverID: configuration.id, configurationRevision: configuration.revision,
            revision: Self.digest(try Self.encoded(material)), tools: sorted, rejectedTools: rejected)
        cachedCatalog = catalog
        return catalog
    }

    private func rpc(_ method: String, params: [String: JSONValue], token: UUID, notification: Bool = false) async throws -> MCPHTTPReply {
        try Task.checkCancellation(); try ensure(token)
        guard nextID < 9_007_199_254_740_991 else { throw MCPClientError.limitExceeded }
        let id = notification ? nil : nextID
        if !notification { nextID += 1 }
        let operationID = UUID(), configuration = configuration, transport = transport, session = sessionID
        let task = Task { try await transport.send(configuration: configuration, method: method, params: params, id: id, sessionID: session) }
        operations[operationID] = task
        defer { operations.removeValue(forKey: operationID) }
        let reply = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation(); try ensure(token)
        if let returned = reply.sessionID, let session, returned != session { throw MCPClientError.invalidResponse }
        guard !reply.catalogChanged else {
            cachedCatalog = nil; resourceCatalog = nil; promptCatalog = nil
            throw MCPClientError.catalogChanged
        }
        return reply
    }
    private func ensure(_ token: UUID) throws {
        guard generation == token else { throw MCPClientError.invalidated }
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
