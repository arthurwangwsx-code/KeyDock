import Foundation
import MCPAdapters
import AgentCore
import AICore
import ExecutionCore

public struct MCPServerDraft {
    public var id = UUID()
    public var name = ""
    public var kind: MCPTransportKind = .http
    public var endpoint = ""
    public var executable = ""
    public var arguments = "[]"
    public var directory = NSHomeDirectory()
    public var startupTimeout = "30"
    public var requestTimeout = "30"
    public var enabled = false
    public var allowsLocalHTTP = false
    public var version: MCPProtocolVersion = .modern20260728
    public var apiKey = ""
    public init() {}
    public init(_ source: MCPServerConfiguration) {
        id = source.id; name = source.name; kind = source.transportKind; endpoint = source.endpoint.absoluteString
        enabled = source.enabled; allowsLocalHTTP = source.allowsLocalHTTP; version = source.protocolVersion
        requestTimeout = String(source.timeoutSeconds)
        if let launch = source.stdioLaunch {
            executable = launch.executable; directory = launch.workingDirectory
            startupTimeout = String(launch.startupTimeoutSeconds)
            arguments = (try? String(data:JSONEncoder().encode(launch.arguments),encoding:.utf8)) ?? "[]"
        }
    }
}

private struct MCPKeychainAccess: MCPSecretProviding {
    let load: @MainActor @Sendable (UUID,String) throws -> String?
    func bearerToken(serverID: UUID,reference: String) async throws -> String? { try await load(serverID,reference) }
}
enum MCPSetupError: Error { case outcomeUnknown }

extension WorkbenchModel {
    func mcpKeyReference(id:UUID,endpoint:URL) -> String { "mcp."+id.uuidString+"."+fingerprint(endpoint.absoluteString) }
    @discardableResult public func saveMCPServer(_ draft: MCPServerDraft, trusted: Bool = false) async -> Bool {
        guard !isShuttingDown, !mcpSettingsChanging else { return false }
        mcpSettingsChanging = true; defer { mcpSettingsChanging = false }
        if !draft.enabled { mcpSessionDisabled.insert(draft.id); await invalidateMCPSource(draft.id) }
        var account: String?, oldKey: String?, keyChanged = false
        do {
            let old = configuration.mcpServers.first{$0.id == draft.id}
            guard let requestTimeout = TimeInterval(draft.requestTimeout) else { throw MCPClientError.invalidConfiguration }
            let source: MCPServerConfiguration
            if draft.kind == .stdio {
                guard !draft.enabled || trusted else { throw MCPClientError.disabled }
                let arguments = try JSONDecoder().decode([String].self,from:Data(draft.arguments.utf8))
                guard let startup = TimeInterval(draft.startupTimeout) else { throw MCPClientError.invalidConfiguration }
                source = MCPServerConfiguration(id:draft.id,name:draft.name,stdio:.init(executable:draft.executable,arguments:arguments,workingDirectory:draft.directory,startupTimeoutSeconds:startup),enabled:draft.enabled,protocolVersion:draft.version,timeoutSeconds:requestTimeout)
            } else {
                guard let endpoint = URL(string:draft.endpoint) else { throw MCPClientError.invalidConfiguration }
                let reference = mcpKeyReference(id:draft.id,endpoint:endpoint)
                let retained = old?.transportKind == .http && old?.endpoint == endpoint ? old?.secretReference:nil
                source = MCPServerConfiguration(id:draft.id,name:draft.name,endpoint:endpoint,allowsLocalHTTP:draft.allowsLocalHTTP,enabled:draft.enabled,protocolVersion:draft.version,secretReference:draft.apiKey.isEmpty ? retained:reference,timeoutSeconds:requestTimeout)
                try source.validate()
                if !draft.apiKey.isEmpty {
                    guard allowContextCapture else { throw MCPClientError.missingCredential }
                    account = reference; oldKey = try credentialReader(reference)
                    keyChanged = true; try credentialWriter(draft.apiKey,reference)
                }
            }
            try source.validate()
            var next = configuration
            if let index = next.mcpServers.firstIndex(where:{$0.id == source.id}) { next.mcpServers[index] = source }
            else { guard next.mcpServers.count < 8 else { throw MCPClientError.limitExceeded }; next.mcpServers.append(source) }
            guard commitSettingsConfiguration(next) else { throw MCPClientError.invalidConfiguration }
            await invalidateMCPSource(source.id)
            if source.enabled { mcpSessionDisabled.remove(source.id) }; return true
        } catch {
            if keyChanged,let account {
                do { try credentialWriter(oldKey ?? "",account) }
                catch { settingsNoticeMessage = noticeKey("MCP settings were not saved and the previous credential could not be restored. Check the stored key."); return false }
            }
            settingsNoticeMessage = noticeKey("MCP server could not be saved. Check configuration and trust settings."); return false
        }
    }
    func makeMCPClient(_ source: MCPServerConfiguration) throws -> MCPHTTPClient {
        guard !isShuttingDown, source.enabled, !mcpSessionDisabled.contains(source.id) else { throw MCPClientError.disabled }
        let secret = MCPKeychainAccess { [weak self] id,reference in
            guard let self, self.allowContextCapture, id == source.id,
                  !self.isShuttingDown,!self.mcpSessionDisabled.contains(id),self.configuration.mcpServers.contains(source),
                  reference == self.mcpKeyReference(id:source.id,endpoint:source.endpoint) else { throw MCPClientError.missingCredential }
            return try self.credentialReader(reference)
        }
        return try MCPHTTPClient(configuration:source,transport:MCPTransportRouter(http:MCPHTTPTransport(secrets:secret)))
    }
    func discoverMCP(_ client: MCPHTTPClient, parentRun: UUID? = nil) async throws -> MCPToolCatalog {
        try Task.checkCancellation()
        let id = UUID(), source = client.configuration
        do { try await agentToolStore.begin(id:id,name:"MCP connection",commandID:(parentRun.map{"keydock.agent."+$0.uuidString} ?? "keydock.mcp-source."+source.id.uuidString),commandVersion:1,configurationFingerprint:source.revision.uuidString,caller:parentRun == nil ? "user":"agent",initialMessage:"mcp.connectionIntent") }
        catch { await agentToolStore.abandonUndispatched(id); throw error }
        let catalog: MCPToolCatalog
        do { catalog = try await client.discover() }
        catch {
            try? await agentToolStore.finish(id:id,result:.init(state:.interrupted,message:"mcp.connectionOutcomeUnknown")); await agentToolStore.releaseProtection(for:id)
            throw MCPSetupError.outcomeUnknown
        }
        do { try await agentToolStore.finish(id:id,result:.init(state:.succeeded,message:"mcp.connectionReady")) }
        catch { await agentToolStore.releaseProtection(for:id); throw AgentToolError.receiptUnavailable }
        await agentToolStore.releaseProtection(for:id); return catalog
    }
    public func connectMCP(_ id: UUID) {
        guard !isShuttingDown, !mcpBusy, !mcpSettingsChanging, let source = configuration.mcpServers.first(where:{$0.id == id && $0.enabled}) else { return }
        mcpSessionDisabled.remove(id)
        mcpBusy = true; let token = mcpGeneration
        mcpConnectionTask = Task { [weak self] in
            guard let self else { return }; defer { mcpBusy = false; mcpConnectionTask = nil }
            var client: MCPHTTPClient?
            do {
                let connection = try makeMCPClient(source); client = connection
                let catalog = try await discoverMCP(connection)
                let capabilities = await connection.availableCapabilities()
                try Task.checkCancellation()
                guard !isShuttingDown, mcpGeneration == token, configuration.mcpServers.contains(where:{$0 == source}) else { throw MCPClientError.invalidated }
                if let old = mcpClients[id] { await old.invalidate() }
                try Task.checkCancellation()
                guard !isShuttingDown,mcpGeneration == token,!mcpSessionDisabled.contains(id),configuration.mcpServers.contains(source) else { throw MCPClientError.invalidated }
                mcpClients[id] = connection; mcpCatalogs[id] = catalog; mcpCapabilities[id] = capabilities; settingsNoticeMessage = .none
            } catch { if let client { await client.invalidate() }; if !isShuttingDown { settingsNoticeMessage = noticeKey("MCP connection failed. Check source, protocol and schema support.") } }
        }
    }
    public func disconnectMCP(_ id: UUID) async { mcpSessionDisabled.insert(id); await invalidateMCPSource(id) }
    func invalidateMCPSource(_ id: UUID) async {
        mcpGeneration = UUID(); mcpConnectionTask?.cancel()
        for (run,sources) in mcpRunScopes where sources.contains(id) { cancelTask(run) }
        if let client = mcpClients.removeValue(forKey:id) { await client.invalidate() }
        mcpCatalogs[id] = nil; mcpResources[id] = nil; mcpPrompts[id] = nil; mcpCapabilities[id] = nil
    }
    public func removeMCPServer(_ id: UUID) async {
        mcpSessionDisabled.insert(id)
        var next = configuration; next.mcpServers.removeAll{$0.id == id}
        guard commitSettingsConfiguration(next) else { await invalidateMCPSource(id); return }
        await invalidateMCPSource(id)
    }
    func prepareMCPTools(_ definition: AgentDefinition, sources:[MCPServerConfiguration], runID: UUID) async throws -> [ScopedAITool] {
        var tools: [ScopedAITool] = [], resolved: Set<String> = []
        mcpRunScopes[runID] = Set(sources.map(\.id))
        for source in sources where definition.allowedMCPToolNames.contains(where:{$0.hasPrefix("mcp_"+String(source.id.uuidString.replacingOccurrences(of:"-",with:"").lowercased().prefix(12))+"_")}) {
            try Task.checkCancellation()
            guard configuration.mcpServers.contains(where:{$0 == source && $0.enabled}) else { throw MCPClientError.invalidated }
            let client = try makeMCPClient(source); mcpRunClients[runID,default:[]].append(client)
            let catalog = try await discoverMCP(client,parentRun:runID)
            for tool in catalog.tools where definition.allowedMCPToolNames.contains(tool.definition.name) {
                resolved.insert(tool.definition.name)
                let scope = fingerprint(source.id.uuidString+"|"+source.revision.uuidString+"|"+catalog.revision+"|"+tool.originalName)
                tools.append(ScopedAITool(definition:tool.definition,effects:[.network,.executeProcess,.writeFile],resource:.exact(namespace:"keydock.mcp",identifier:scope),approvalSummary:source.name+"\n"+source.endpoint.absoluteString+"\n"+tool.originalName) { arguments,_ in
                    let result = try await client.call(modelToolName:tool.definition.name,arguments:arguments,catalogRevision:catalog.revision)
                    guard !result.isError else { throw AgentToolError.toolFailed }
                    var text = result.text
                    if let structured = result.structuredContent { text += "\n"+String(decoding:try JSONEncoder().encode(structured),as:UTF8.self) }
                    guard text.utf8.count <= 65_536 else { throw AIProviderError.outputLimit }; return text
                })
            }
        }
        guard resolved == definition.allowedMCPToolNames else { throw MCPClientError.catalogChanged }
        return tools
    }
    func closeMCPRun(_ id: UUID) async {
        let clients = mcpRunClients.removeValue(forKey:id) ?? []; mcpRunScopes[id] = nil
        for client in clients { await client.invalidate() }
    }
    public func browseMCPResources(_ id: UUID) {
        let token = mcpGeneration
        performMCPContext(id) { client,source in
            let value = try await client.listResources(selection:source)
            guard !Task.isCancelled,!self.isShuttingDown,self.mcpGeneration == token else { return }; self.mcpResources[id] = value
        }
    }
    public func browseMCPPrompts(_ id: UUID) {
        let token = mcpGeneration
        performMCPContext(id) { client,source in
            let value = try await client.listPrompts(selection:source)
            guard !Task.isCancelled,!self.isShuttingDown,self.mcpGeneration == token else { return }; self.mcpPrompts[id] = value
        }
    }
    public func readMCPResource(_ id: UUID, uri:String,session:WorkspaceSession) {
        guard let catalog = mcpResources[id], let selection = try? catalog.select(uri:uri), let selectedName = catalog.resources.first(where:{$0.uri == uri})?.name else { return }
        var context: UUID?
        let token = mcpGeneration, sourceName = (configuration.mcpServers.first(where:{$0.id == id})?.name ?? L("MCP resource")) + " · " + selectedName
        performMCPContext(id,prepare:{ context = self.beginTextContextImport(session); return context != nil }) { client,_ in
            guard let context else { return }
            let result = try await client.readResource(selection:selection)
            guard !Task.isCancelled,!self.isShuttingDown,self.mcpGeneration == token,session.contextGeneration == context else { return }
            if self.commitTextContext(result.contents.map(\.text).joined(separator:"\n"),kind:.mcpResource,name:sourceName,session:session,token:context,mcpSourceID:id) { self.onOpenWorkspace?(.tools) }
        }
    }
    public func readMCPPrompt(_ id: UUID,name:String,arguments:String,session:WorkspaceSession) {
        guard let catalog = mcpPrompts[id], let selection = try? catalog.select(name:name), let prompt = catalog.prompts.first(where:{$0.name == name}) else { return }
        let values: [String:String]
        do {
            guard arguments.utf8.count <= 65_536 else { throw MCPClientError.limitExceeded }
            values = try JSONDecoder().decode([String:String].self,from:Data(arguments.utf8))
            try prompt.validateArguments(values)
        } catch { settingsNoticeMessage = noticeKey("MCP content could not be loaded. Refresh the source and try again."); return }
        var context: UUID?
        let token = mcpGeneration, sourceName = (configuration.mcpServers.first(where:{$0.id == id})?.name ?? L("MCP prompt")) + " · " + name
        performMCPContext(id,prepare:{ context = self.beginTextContextImport(session); return context != nil }) { client,_ in
            guard let context else { return }
            let result = try await client.getPrompt(selection:selection,arguments:values)
            guard !Task.isCancelled,!self.isShuttingDown,self.mcpGeneration == token,session.contextGeneration == context else { return }
            if self.commitTextContext(result.messages.map{"["+$0.role.rawValue+"]\n"+$0.text}.joined(separator:"\n\n"),kind:.mcpPrompt,name:sourceName,session:session,token:context,mcpSourceID:id) { self.onOpenWorkspace?(.tools) }
        }
    }
    private func performMCPContext(_ id: UUID, prepare:@MainActor ()->Bool = { true }, operation:@escaping @MainActor (MCPHTTPClient,MCPExplicitSourceSelection) async throws->Void) {
        guard !isShuttingDown,!mcpBusy,!mcpSessionDisabled.contains(id),let client = mcpClients[id],let source = configuration.mcpServers.first(where:{$0.id == id && $0.enabled}),source == client.configuration else { return }
        mcpBusy = true
        guard prepare() else { mcpBusy = false; return }
        mcpConnectionTask = Task { [weak self] in
            guard let self else { return }; defer { mcpBusy = false; mcpConnectionTask = nil }
            do { try await operation(client,.init(serverID:id,configurationRevision:source.revision)); try Task.checkCancellation() }
            catch { if !isShuttingDown { settingsNoticeMessage = noticeKey("MCP content could not be loaded. Refresh the source and try again.") } }
        }
    }
}
