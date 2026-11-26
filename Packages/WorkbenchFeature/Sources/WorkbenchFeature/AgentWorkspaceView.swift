import SwiftUI
import AgentCore
import KeyDockUI
import AICore

struct AgentWorkspaceView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @State private var confirmRemoval = false
    var body: some View {
        Form {
            Section(L("Agent workspace")) {
                Picker(L("Agent profile"),selection:Binding(get:{session.agentProfile.id},set:{ id in if let profile = store.configuration.agents.first(where:{$0.id == id}) { session.agentProfile = profile } })) {
                    if !store.configuration.agents.contains(where:{$0.id == session.agentProfile.id}) { Text(L("Unsaved profile")).tag(session.agentProfile.id) }
                    ForEach(store.configuration.agents) { profile in Text(profile.name).tag(profile.id) }
                }
                HStack {
                    TextField(L("Name"),text:$session.agentProfile.name)
                    Button(L("New profile")) { session.agentProfile = AgentDefinition() }
                    Button(L("Save profile")) { session.saveAgentProfile(in: store) }.disabled(!session.hasValidAgentTokenThresholdDraft)
                    if store.configuration.agents.contains(where:{$0.id == session.agentProfile.id}) { Button(L("Remove"),role:.destructive) { confirmRemoval = true } }
                }
                let saveState = session.agentProfileSaveState(in: store)
                Label(saveState.title, systemImage: saveState.symbol).font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$session.agentProfile.instructions).font(.body).frame(minHeight:90).modifier(KDReadingSurface()).accessibilityLabel(L("Agent instructions"))
                DisclosureGroup(L("Model and reasoning overrides")) {
                    AIModelSettingsFields(options: Binding(get: { session.agentProfile.modelOptions ?? .init(model: session.agentProfile.modelOverride) }, set: { session.agentProfile.modelOptions = $0; session.agentProfile.modelOverride = "" }),
                        endpoint: store.configuration.endpoint, globalModel: store.configuration.model, settings: store.configuration.aiModelSettings,
                        scene: .agent, localHTTP: store.configuration.localHTTP, language: store.configuration.language, requiresTools: true,
                        inventoryModels: store.savedServiceModels)
                }
            }
            DisclosureGroup(L("Tools and budgets")) {
                Label(L("Current time · read only"),systemImage:"clock")
                ForEach(store.configuration.savedCommands) { command in
                    Toggle(command.name,isOn:Binding(get:{session.agentProfile.allowedCommandIDs.contains(command.id)},set:{ if $0 { session.agentProfile.allowedCommandIDs.insert(command.id) } else { session.agentProfile.allowedCommandIDs.remove(command.id) } })).disabled(command.interactive && !session.agentProfile.allowedCommandIDs.contains(command.id))
                }
                ForEach(session.agentProfile.allowedCommandIDs.filter { id in !store.configuration.savedCommands.contains(where: { $0.id == id }) }.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    HStack {
                        Text(L("Unavailable saved command") + ": " + id.uuidString).font(.caption)
                        Spacer()
                        Button(L("Remove unavailable tool")) { session.agentProfile.allowedCommandIDs.remove(id) }
                    }
                }
                ForEach(store.configuration.mcpServers) { source in
                    Toggle(source.name,isOn:Binding(get:{session.agentProfile.allowedMCPServerIDs.contains(source.id)},set:{ enabled in
                        if enabled { session.agentProfile.allowedMCPServerIDs.insert(source.id) }
                        else {
                            session.agentProfile.allowedMCPServerIDs.remove(source.id)
                            let prefix = "mcp_"+String(source.id.uuidString.replacingOccurrences(of:"-",with:"").lowercased().prefix(12))+"_"
                            session.agentProfile.allowedMCPToolNames = session.agentProfile.allowedMCPToolNames.filter{!$0.hasPrefix(prefix)}
                        }
                    })).disabled(!source.enabled && !session.agentProfile.allowedMCPServerIDs.contains(source.id))
                    if session.agentProfile.allowedMCPServerIDs.contains(source.id), let catalog = store.mcpCatalogs[source.id] {
                        ForEach(catalog.tools) { tool in
                            Toggle(tool.originalName,isOn:Binding(get:{session.agentProfile.allowedMCPToolNames.contains(tool.definition.name)},set:{if $0 {session.agentProfile.allowedMCPToolNames.insert(tool.definition.name)} else {session.agentProfile.allowedMCPToolNames.remove(tool.definition.name)}})).padding(.leading,16)
                        }
                    }
                }
                ForEach(session.agentProfile.allowedMCPServerIDs.filter { id in !store.configuration.mcpServers.contains(where: { $0.id == id }) }.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    HStack {
                        Text(L("Unavailable MCP source") + ": " + id.uuidString).font(.caption)
                        Spacer()
                        Button(L("Remove unavailable source")) {
                            session.agentProfile.allowedMCPServerIDs.remove(id)
                            session.agentProfile.allowedMCPToolNames = session.agentProfile.allowedMCPToolNames.filter { !MCPToolReference.references($0, sourceID: id) }
                        }
                    }
                }
                let visibleTools = Set(store.mcpCatalogs.filter { session.agentProfile.allowedMCPServerIDs.contains($0.key) }.values.flatMap { $0.tools.map(\.definition.name) })
                ForEach(session.agentProfile.allowedMCPToolNames.subtracting(visibleTools).sorted(), id: \.self) { name in
                    HStack {
                        Text(L("Saved MCP tool") + ": " + name).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button(L("Remove saved tool")) { session.agentProfile.allowedMCPToolNames.remove(name) }
                    }
                }
                Button(L("Manage MCP servers")) { store.onOpenSettings?(.mcp) }
                Stepper(L("Tool calls")+": \(session.agentProfile.maxToolCalls)",value:$session.agentProfile.maxToolCalls,in:0...20)
                Stepper(L("Model turns")+": \(session.agentProfile.maxTurns)",value:$session.agentProfile.maxTurns,in:1...16)
                Stepper(L("Time budget (seconds)")+": \(session.agentProfile.timeoutSeconds)",value:$session.agentProfile.timeoutSeconds,in:15...300,step:15)
                Toggle(L("Stop at a reported token threshold"), isOn: Binding(get: { session.agentProfile.maxRunTokens != nil }, set: session.setAgentTokenThresholdEnabled))
                if session.agentProfile.maxRunTokens != nil {
                    TextField(L("Reported token threshold"), text: Binding(get: { session.agentRunTokenText }, set: session.setAgentTokenThresholdText))
                    if !session.hasValidAgentTokenThresholdDraft { KDInlineNotice(L("Enter a whole number from 1 to 1000000000.")) }
                    Text(L("Counts include reported input and output tokens. Missing or conflicting usage pauses the run. A request can exceed this threshold before its usage is returned; this is not a billing hard limit.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Budgets are frozen when a run starts. Profile edits affect new runs; pause the current run to stop it.")).font(.caption).foregroundStyle(.secondary)
                Text(L("Tool scope is frozen when a run starts. Every command call needs approval; its output is sent to the selected model. Cancelling does not undo effects already completed.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Your task")) {
                TextEditor(text:$session.agentInput).font(.body).frame(minHeight:140).modifier(KDReadingSurface()).accessibilityLabel(L("Agent task input"))
                Button(L("Run agent")) { store.performUserInputAction { store.runAgent(session.agentProfile,input:session.agentInput) } }.buttonStyle(.borderedProminent).disabled(session.agentInput.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !session.hasValidAgentTokenThresholdDraft)
            }
        }.formStyle(.grouped).confirmationDialog(L("Remove this Agent profile? Running tasks keep their original snapshot."),isPresented:$confirmRemoval) { Button(L("Remove"),role:.destructive) { if store.removeAgent(session.agentProfile.id) { session.agentProfile = store.configuration.agents.first ?? AgentDefinition() } } }.onAppear {
            if !session.agentProfileLoaded { session.agentProfile = store.configuration.agents.first ?? AgentDefinition(); session.agentProfileLoaded = true }
        }
    }
}

struct AgentApprovalView: View {
    @ObservedObject var store: WorkbenchModel
    let runID: UUID
    var body: some View {
        ForEach(store.pendingApprovals.filter {$0.runID == runID}) { approval in
            VStack(alignment:.leading,spacing:10) {
                Label(L("Approve this tool call?"),systemImage:"hand.raised")
                Text(approval.displayTitle).font(.headline).lineLimit(2).textSelection(.enabled)
                if approval.displayTitle != approval.toolName {
                    Text(L("Tool identifier") + ": " + approval.toolName).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ScrollView { Text(approval.summary).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:180)
                Text(L("This tool may change your computer. Review its full arguments. Output may be sent to AI by this run.")).font(.caption).foregroundStyle(.secondary)
                if approval.runContractFingerprint != nil {
                    Text(L("Frozen run token threshold") + ": " + (approval.maxRunTokens.map(String.init) ?? L("Off"))).font(.caption)
                    Text(L("Profile edits affect new runs. Pause this run before changing its execution budget.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Deny")) { store.resolveApproval(approval.id,approved:false) }
                    Button(L("Approve once")) { store.resolveApproval(approval.id,approved:true) }.buttonStyle(.borderedProminent)
                }
            }.padding(16).modifier(KDReadingSurface())
        }
    }
}
