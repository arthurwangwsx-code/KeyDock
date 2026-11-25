import Foundation

public enum ContributionCatalogError: Error, Equatable, Sendable {
    case invalidManifest, duplicateContribution, duplicateProvider, duplicateHandler
    case providerUnavailable, handlerUnavailable, handlerContractMismatch
    case unavailable, staleSnapshot, versionMismatch, invalidInput
}

/// 声明引用已编译的provider和handler，不包含动态库、脚本或授权。
public struct ContributionManifest: Hashable, Sendable {
    public let reference: CommandExecutionReference
    public let provider: CommandExecutionReference
    public let descriptor: CommandDescriptor
    public let commandPrefixes: [String]
    public let payloadPrefixes: [String]
    public let kinds: Set<CommandKind>
    public init(reference: CommandExecutionReference, provider: CommandExecutionReference, descriptor: CommandDescriptor,
                commandPrefixes:[String] = [], payloadPrefixes:[String] = [], kinds:Set<CommandKind> = []) throws {
        guard descriptor.id == reference.toolID, descriptor.version == reference.toolVersion,
              descriptor.providerID == provider.toolID, commandPrefixes.count <= 16, payloadPrefixes.count <= 16,
              (commandPrefixes+payloadPrefixes).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { throw ContributionCatalogError.invalidManifest }
        self.reference = reference; self.provider = provider; self.descriptor = descriptor
        self.commandPrefixes = commandPrefixes; self.payloadPrefixes = payloadPrefixes; self.kinds = kinds
    }
    public func ownsCommandID(_ id:String) -> Bool { commandPrefixes.contains { id.hasPrefix($0) } }
    public func owns(_ item:CommandItem) -> Bool { ownsCommandID(item.id) || payloadPrefixes.contains { item.payload.hasPrefix($0) } || kinds.contains(item.kind) }
}

/// 与真实函数同时注册的合同；不接受manifest自行放宽输入、context或effects。
public struct ContributionHandlerContract: Hashable, Sendable {
    public let reference: CommandExecutionReference
    public let inputType: CommandValueType
    public let outputType: CommandValueType
    public let requiredContext: Set<CommandContextRequirement>
    public let effects: Set<CommandEffect>
    public init(action: ActionDescriptor) {
        reference = action.execution; inputType = action.inputType; outputType = action.outputType
        requiredContext = action.requiredContext; effects = action.effects
    }
    func accepts(_ action: ActionDescriptor) -> Bool {
        reference == action.execution && inputType == action.inputType && outputType == action.outputType &&
        requiredContext == action.requiredContext && effects == action.effects
    }
}

public struct CommandContributionReference: Hashable, Codable, Sendable {
    public let contribution: CommandExecutionReference
    public let action: CommandExecutionReference
    public init(contribution: CommandExecutionReference, action: CommandExecutionReference) { self.contribution = contribution; self.action = action }
}

public struct CommandContributionBinding: Hashable, Codable, Sendable {
    public let reference: CommandContributionReference
    public let epoch: UUID
    public let input: String?
    public init(reference: CommandContributionReference, epoch: UUID, input: String? = nil) throws {
        guard (input?.utf8.count ?? 0) <= 131_072 else { throw ContributionCatalogError.invalidInput }
        self.reference = reference; self.epoch = epoch; self.input = input
    }
    private enum CodingKeys: String, CodingKey { case reference, epoch, input }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        try self.init(reference:values.decode(CommandContributionReference.self,forKey:.reference),epoch:values.decode(UUID.self,forKey:.epoch),input:values.decodeIfPresent(String.self,forKey:.input))
    }
}

public struct ResolvedContributionAction: Sendable {
    public let manifest: ContributionManifest
    public let descriptor: CommandDescriptor
    public let action: ActionDescriptor
    public let epoch: UUID
}

public struct CompiledContributionCatalog: Sendable {
    public let manifests: [ContributionManifest]
    public init(manifests: [ContributionManifest], providers: [CommandExecutionReference], handlers: [ContributionHandlerContract]) throws {
        guard manifests.count <= 64, providers.count <= 128, handlers.count <= 256 else { throw ContributionCatalogError.invalidManifest }
        guard Set(manifests.map { $0.reference.toolID }).count == manifests.count else { throw ContributionCatalogError.duplicateContribution }
        guard Set(providers).count == providers.count else { throw ContributionCatalogError.duplicateProvider }
        guard Set(handlers.map(\.reference)).count == handlers.count else { throw ContributionCatalogError.duplicateHandler }
        for first in manifests.indices {
            for second in manifests.indices where second > first {
                let a = manifests[first], b = manifests[second]
                let commandsOverlap = a.commandPrefixes.contains { left in b.commandPrefixes.contains { left.hasPrefix($0) || $0.hasPrefix(left) } }
                let payloadsOverlap = a.payloadPrefixes.contains { left in b.payloadPrefixes.contains { left.hasPrefix($0) || $0.hasPrefix(left) } }
                guard !commandsOverlap, !payloadsOverlap, a.kinds.isDisjoint(with:b.kinds) else { throw ContributionCatalogError.invalidManifest }
            }
        }
        let handlerMap = Dictionary(uniqueKeysWithValues:handlers.map { ($0.reference,$0) })
        for manifest in manifests {
            guard providers.contains(manifest.provider) else { throw ContributionCatalogError.providerUnavailable }
            for action in manifest.descriptor.actions {
                guard let handler = handlerMap[action.execution] else { throw ContributionCatalogError.handlerUnavailable }
                guard handler.accepts(action) else { throw ContributionCatalogError.handlerContractMismatch }
            }
        }
        self.manifests = manifests
    }
    public func snapshot(disabled: Set<String>, epoch: UUID) -> ContributionCatalogSnapshot {
        .init(manifests:manifests,disabled:disabled,epoch:epoch)
    }
}

public struct ContributionCatalogSnapshot: Sendable {
    public let manifests: [ContributionManifest]
    public let disabled: Set<String>
    public let epoch: UUID
    fileprivate init(manifests:[ContributionManifest],disabled:Set<String>,epoch:UUID) { self.manifests = manifests; self.disabled = disabled; self.epoch = epoch }
    public func isEnabled(_ id: String) -> Bool { manifests.contains { $0.reference.toolID == id } && !disabled.contains(id) }
    public func binding(for id:String, actionID:String? = nil, input:String? = nil) throws -> CommandContributionBinding {
        guard let manifest = manifests.first(where:{$0.reference.toolID == id}), isEnabled(id) else { throw ContributionCatalogError.unavailable }
        let selected = actionID ?? manifest.descriptor.defaultActionID
        guard let action = manifest.descriptor.actions.first(where:{$0.id == selected}) else { throw ContributionCatalogError.unavailable }
        return try .init(reference:.init(contribution:manifest.reference,action:.init(toolID:action.id,toolVersion:action.version)),epoch:epoch,input:input)
    }
    public func resolve(_ binding:CommandContributionBinding, instanceID:String, title:String, keywords:[String] = []) throws -> ResolvedContributionAction {
        guard binding.epoch == epoch else { throw ContributionCatalogError.staleSnapshot }
        guard let manifest = manifests.first(where:{$0.reference.toolID == binding.reference.contribution.toolID}), isEnabled(manifest.reference.toolID) else { throw ContributionCatalogError.unavailable }
        guard manifest.reference == binding.reference.contribution,
              let action = manifest.descriptor.actions.first(where:{$0.id == binding.reference.action.toolID && $0.version == binding.reference.action.toolVersion}) else { throw ContributionCatalogError.versionMismatch }
        let descriptor = try CommandDescriptor(id:instanceID,version:manifest.descriptor.version,title:title,providerID:manifest.provider.toolID,keywords:keywords,
            availability:manifest.descriptor.availability,actions:manifest.descriptor.actions,defaultActionID:action.id)
        return .init(manifest:manifest,descriptor:descriptor,action:action,epoch:epoch)
    }
}
