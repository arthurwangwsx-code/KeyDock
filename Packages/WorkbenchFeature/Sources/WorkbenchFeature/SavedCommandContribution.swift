import Foundation
import CommandCore
import ExecutionCore
import CryptoKit

/// 不含启用代次；在途任务持有确切声明版本，不因随后开关或编辑而重绑定。
struct FrozenCommandContribution: Codable, Sendable {
    let contribution: CommandExecutionReference
    let action: CommandExecutionReference
    let execution: CommandExecutionReference
    init(_ resolved:ResolvedContributionAction) throws {
        try self.init(manifest:resolved.manifest,action:resolved.action)
    }
    init(manifest:ContributionManifest,action selected:ActionDescriptor? = nil) throws {
        let selected = selected ?? manifest.descriptor.defaultAction
        guard manifest.descriptor.actions.contains(selected) else { throw ContributionCatalogError.versionMismatch }
        contribution = manifest.reference
        action = try .init(toolID:selected.id,toolVersion:selected.version)
        execution = selected.execution
    }
    func fingerprint(_ command:SavedCommand) throws -> String {
        struct Resource: Encodable { let command:SavedCommand; let contract:FrozenCommandContribution }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data:try encoder.encode(Resource(command:command,contract:self))).map { String(format:"%02x",$0) }.joined()
    }
}

struct PreparedSavedCommand: Sendable {
    let command: SavedCommand
    let showWorkspace: Bool
    var attempt: AttemptExecutionContext? = nil
}

enum SavedCommandContribution {
    static func manifest() throws -> ContributionManifest {
        let action = try HostActionCatalog.action(.runCommand,title:"Run saved command")
        let providerRef = try CommandExecutionReference(toolID:"keydock.provider.commands",toolVersion:1)
        return try ContributionManifest(reference:.init(toolID:BuiltinContributionID.commands,toolVersion:1),provider:providerRef,
            descriptor:.init(id:BuiltinContributionID.commands,version:1,title:"Command line tools",providerID:providerRef.toolID,actions:[action]),commandPrefixes:["command."],kinds:[.command])
    }
    @MainActor static func definition() throws -> BuiltinContributionDefinition {
        let manifest = try manifest(), action = manifest.descriptor.defaultAction
        let provider = ContributionProviderRegistration(manifest:manifest,
            presentation:{(L("Command line tools"),L("Run saved commands directly or in workflows and agents. Editing saved commands stays available."))},dismissAfterSelection:true,
            catalogItems:{store,snapshot in
                let binding = try snapshot.binding(for:BuiltinContributionID.commands)
                return try store.configuration.savedCommands.map { command in
                    CommandItem(id:"command."+command.id.uuidString,title:command.name,subtitle:command.executable,kind:.command,payload:command.id.uuidString,objectRevision:try store.fingerprint(command),contribution:binding)
                }
            },querySource:{_,_,_,_ in nil},prepareItem:{store,item in
                guard item.kind == .command, item.contribution?.input == nil, let command = store.configuration.savedCommands.first(where:{$0.id.uuidString == item.payload}),
                      item.id == "command."+command.id.uuidString, item.objectRevision == (try store.fingerprint(command)) else { throw ContributionCatalogError.invalidInput }
                return PreparedSavedCommand(command:command,showWorkspace:false)
            },read:nil)
        let handler = ContributionHandlerRegistration(contract:.init(action:action),body:.immediate {store,resolved,payload,caller in
            guard let prepared = payload as? PreparedSavedCommand else { throw ContributionCatalogError.invalidInput }
            guard let id = store.runPreparedCommand(prepared.command,resolved:resolved,caller:caller,showWorkspace:prepared.showWorkspace,attempt:prepared.attempt) else { return .rejected }
            return .started(id)
        })
        return .init(provider:provider,handlers:[handler])
    }
}

extension WorkbenchModel {
    func prepareCommandContribution(_ command:SavedCommand) throws -> ResolvedContributionAction {
        try command.validate()
        let binding = try contributionSnapshot.binding(for:BuiltinContributionID.commands)
        return try resolveContribution(binding,id:"command."+command.id.uuidString,title:command.name)
    }
    /// 新工作流／Agent先冻结同一注册版本；实际工具仍走各自Broker及原审批。
    func requireCommandContribution() throws -> ResolvedContributionAction {
        let binding = try contributionSnapshot.binding(for:BuiltinContributionID.commands)
        return try resolveContribution(binding,id:"command.snapshot",title:"Command snapshot")
    }
    func installedCommandContribution() throws -> FrozenCommandContribution {
        guard let manifest = contributions.catalog.manifests.first(where:{$0.reference.toolID == BuiltinContributionID.commands}) else { throw ContributionCatalogError.unavailable }
        return try .init(manifest:manifest)
    }
}
