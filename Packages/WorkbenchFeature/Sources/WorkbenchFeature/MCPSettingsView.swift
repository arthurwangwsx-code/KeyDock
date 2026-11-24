import SwiftUI
import MCPAdapters
import KeyDockUI

struct MCPSettingsContent: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @State private var confirmTrust = false
    @State private var removeID: UUID?
    var body: some View {
        Section(L("MCP servers")) {
            Text(L("Only enable sources you trust. Local servers run as your user and can access files or run commands outside KeyDock. This is not an OS sandbox. Connections start only when you connect or start an allowed Agent run.")).font(.caption).foregroundStyle(.secondary)
            ForEach(store.configuration.mcpServers) { source in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Label(source.name,systemImage:source.transportKind == .stdio ? "terminal":"network")
                        Spacer()
                        Text(source.enabled ? L("Enabled"):L("Disabled")).font(.caption).foregroundStyle(.secondary)
                        Button(L("Edit")) { session.mcpDraft = MCPServerDraft(source) }
                        Button(L("Remove"),role:.destructive) { removeID = source.id }
                    }
                    HStack {
                        Button(L("Connect / refresh")) { store.connectMCP(source.id) }.disabled(!source.enabled || store.mcpBusy || store.mcpSettingsChanging)
                        Button(L("Disconnect")) { Task { await store.disconnectMCP(source.id) } }
                        if let catalog = store.mcpCatalogs[source.id] {
                            Text(L("Available tools")+": \(catalog.tools.count) · "+L("Unavailable tools")+": \(catalog.rejectedTools.count)").font(.caption)
                        }
                    }
                    if let catalog = store.mcpCatalogs[source.id], !catalog.rejectedTools.isEmpty {
                        Text(L("Some tool schemas are unsupported and cannot be called. These tools are excluded from Agent runs.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button(L("New server")) { session.mcpDraft = MCPServerDraft() }
        }
        Section(L("Server configuration")) {
            TextField(L("Name"),text:$session.mcpDraft.name)
            Picker(L("Connection type"),selection:$session.mcpDraft.kind) {
                Text(L("HTTP endpoint")).tag(MCPTransportKind.http); Text(L("Local process")).tag(MCPTransportKind.stdio)
            }
            if session.mcpDraft.kind == .http {
                TextField(L("MCP endpoint URL"),text:$session.mcpDraft.endpoint)
                SecureField(L("Bearer key · leave blank to keep"),text:$session.mcpDraft.apiKey).disabled(!store.allowContextCapture)
                Toggle(L("Allow HTTP for localhost only"),isOn:$session.mcpDraft.allowsLocalHTTP)
                Text(L("Credentials are stored in Keychain and bound to this server and endpoint. Changing the endpoint does not reuse the old key.")).font(.caption).foregroundStyle(.secondary)
            } else {
                TextField(L("Executable (absolute path)"),text:$session.mcpDraft.executable)
                TextField(L("Arguments (JSON array)"),text:$session.mcpDraft.arguments)
                TextField(L("Working directory"),text:$session.mcpDraft.directory)
                Text(L("Arguments are passed individually. The server receives a minimal environment, not your model credentials or terminal environment.")).font(.caption).foregroundStyle(.secondary)
            }
            Picker(L("Protocol version"),selection:$session.mcpDraft.version) { ForEach(MCPProtocolVersion.allCases,id:\.self) { value in Text(value.rawValue).tag(value) } }
            Toggle(L("Enable when saved"),isOn:$session.mcpDraft.enabled)
            Button(L("Save server")) {
                if session.mcpDraft.kind == .stdio && session.mcpDraft.enabled { confirmTrust = true } else { save(trusted:false) }
            }.disabled(store.mcpSettingsChanging)
        }
        .confirmationDialog(L("Trust this local server?"),isPresented:$confirmTrust) {
            Button(L("Trust and save")) { save(trusted:true) }
        } message: { Text(L("This executable can act with your user permissions whenever the enabled source is connected. Review its path, arguments and working directory before trusting it.")) }
        .confirmationDialog(L("Remove this MCP source?"),isPresented:Binding(get:{removeID != nil},set:{if !$0 {removeID = nil}})) {
            Button(L("Remove"),role:.destructive) { if let id = removeID { Task { await store.removeMCPServer(id) } }; removeID = nil }
        }
    }
    private func save(trusted:Bool) {
        let draft = session.mcpDraft
        Task { if await store.saveMCPServer(draft,trusted:trusted) { session.mcpDraft.apiKey = "" } }
    }
}

struct MCPContentPanel: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    var body: some View {
        Section(L("MCP resources and prompts")) {
            Picker(L("Source"),selection:$session.selectedMCPSourceID) {
                Text(L("Choose a source")).tag(UUID?.none)
                ForEach(store.configuration.mcpServers.filter(\.enabled)) { source in Text(source.name).tag(Optional(source.id)) }
            }
            Button(L("Manage MCP servers")) { store.onOpenSettings?(.mcp) }
            if let id = session.selectedMCPSourceID {
                HStack {
                    Button(L("List resources")) { store.browseMCPResources(id) }.disabled(store.mcpBusy || store.mcpCapabilities[id]?.contains("resources") != true)
                    Button(L("List prompts")) { store.browseMCPPrompts(id) }.disabled(store.mcpBusy || store.mcpCapabilities[id]?.contains("prompts") != true)
                    if store.mcpBusy { ProgressView().controlSize(.small) }
                }
                if let catalog = store.mcpResources[id] {
                    ForEach(catalog.resources) { resource in
                        HStack {
                            VStack(alignment:.leading) { Text(resource.name).lineLimit(1); Text(resource.uri).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer(); Button(L("Preview text")) { store.readMCPResource(id,uri:resource.uri,session:session) }.disabled(store.mcpBusy)
                        }
                    }
                }
                if let catalog = store.mcpPrompts[id] {
                    TextField(L("Prompt arguments (JSON object of strings)"),text:$session.mcpPromptArguments)
                    ForEach(catalog.prompts) { prompt in
                        HStack { Text(prompt.name).lineLimit(1); Spacer(); Button(L("Preview prompt")) { store.readMCPPrompt(id,name:prompt.name,arguments:session.mcpPromptArguments,session:session) }.disabled(store.mcpBusy) }
                    }
                }
            }
            Text(L("Content is loaded only after you choose it, then shown as text for review. Prompts cannot change permissions or become system instructions. Nothing is sent to your AI service automatically.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
