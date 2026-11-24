import Foundation

public enum CommandValueType: String, Codable, Hashable, Sendable, CaseIterable {
    case none, text, application, window, file, url, clipboardItem, commandProposal, structuredData
}

public enum CommandAvailability: Codable, Hashable, Sendable {
    case available
    /// 使用可本地化的稳定原因键，避免在目录和普通日志中暴露原始内容。
    case unavailable(reasonKey: String)
}

public enum CommandContextRequirement: String, Codable, Hashable, Sendable, CaseIterable {
    case frontmostApplication, window, selection, clipboard, workingDirectory, explicitInput
}

/// 这是宿主注册的能力声明；模型输入不能覆盖这些效果。
public enum CommandEffect: String, Codable, Hashable, Sendable, CaseIterable {
    case read, activateApplication, activateWindow, executeProcess, replaceText
    case writeClipboard, writeFile, network, publish
    case modifyWindow, changeApplicationVisibility, terminateApplication
}

public enum CommandContractError: Error, Equatable, Sendable {
    case invalidIdentifier, invalidVersion, emptyTitle, emptyEffects, missingActions, duplicateActionID, invalidDefaultAction
}

public struct CommandExecutionReference: Codable, Hashable, Sendable {
    public let toolID: String
    public let toolVersion: Int

    public init(toolID: String, toolVersion: Int) throws {
        try CommandContractValidation.identifier(toolID)
        guard toolVersion > 0 else { throw CommandContractError.invalidVersion }
        self.toolID = toolID; self.toolVersion = toolVersion
    }

    private enum CodingKeys: String, CodingKey { case toolID, toolVersion }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(toolID: c.decode(String.self, forKey: .toolID), toolVersion: c.decode(Int.self, forKey: .toolVersion))
    }
}

public struct ActionDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let title: String
    public let inputType: CommandValueType
    public let outputType: CommandValueType
    public let availability: CommandAvailability
    public let requiredContext: Set<CommandContextRequirement>
    public let effects: Set<CommandEffect>
    public let execution: CommandExecutionReference

    public init(
        id: String, version: Int, title: String,
        inputType: CommandValueType = .none, outputType: CommandValueType = .none,
        availability: CommandAvailability = .available,
        requiredContext: Set<CommandContextRequirement> = [],
        effects: Set<CommandEffect>, execution: CommandExecutionReference
    ) throws {
        try CommandContractValidation.identifier(id)
        guard version > 0 else { throw CommandContractError.invalidVersion }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandContractError.emptyTitle }
        guard !effects.isEmpty else { throw CommandContractError.emptyEffects }
        self.id = id; self.version = version; self.title = title
        self.inputType = inputType; self.outputType = outputType; self.availability = availability
        self.requiredContext = requiredContext; self.effects = effects; self.execution = execution
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, title, inputType, outputType, availability, requiredContext, effects, execution
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id), version: c.decode(Int.self, forKey: .version),
            title: c.decode(String.self, forKey: .title), inputType: c.decode(CommandValueType.self, forKey: .inputType),
            outputType: c.decode(CommandValueType.self, forKey: .outputType),
            availability: c.decode(CommandAvailability.self, forKey: .availability),
            requiredContext: c.decode(Set<CommandContextRequirement>.self, forKey: .requiredContext),
            effects: c.decode(Set<CommandEffect>.self, forKey: .effects),
            execution: c.decode(CommandExecutionReference.self, forKey: .execution)
        )
    }
}

public struct CommandDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let title: String
    public let providerID: String
    public let keywords: [String]
    public let availability: CommandAvailability
    public let actions: [ActionDescriptor]
    public let defaultActionID: String
    public var defaultAction: ActionDescriptor { actions.first { $0.id == defaultActionID } ?? actions[0] }
    public var inputType: CommandValueType { defaultAction.inputType }
    public var outputType: CommandValueType { defaultAction.outputType }

    public init(
        id: String, version: Int, title: String, providerID: String, keywords: [String] = [],
        availability: CommandAvailability = .available, actions: [ActionDescriptor], defaultActionID: String? = nil
    ) throws {
        try CommandContractValidation.identifier(id)
        try CommandContractValidation.identifier(providerID)
        guard version > 0 else { throw CommandContractError.invalidVersion }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandContractError.emptyTitle }
        guard let first = actions.first else { throw CommandContractError.missingActions }
        guard Set(actions.map(\.id)).count == actions.count else { throw CommandContractError.duplicateActionID }
        let selected = defaultActionID ?? first.id
        guard actions.contains(where: { $0.id == selected }) else { throw CommandContractError.invalidDefaultAction }
        self.id = id; self.version = version; self.title = title; self.providerID = providerID
        self.keywords = keywords; self.availability = availability; self.actions = actions; self.defaultActionID = selected
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, title, providerID, keywords, availability, actions, defaultActionID
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id), version: c.decode(Int.self, forKey: .version),
            title: c.decode(String.self, forKey: .title), providerID: c.decode(String.self, forKey: .providerID),
            keywords: c.decode([String].self, forKey: .keywords),
            availability: c.decode(CommandAvailability.self, forKey: .availability),
            actions: c.decode([ActionDescriptor].self, forKey: .actions),
            defaultActionID: c.decode(String.self, forKey: .defaultActionID)
        )
    }
}

private enum CommandContractValidation {
    static func identifier(_ id: String) throws {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        let valid = id.utf8.count <= 512 && parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
            }
        }
        guard valid else { throw CommandContractError.invalidIdentifier }
    }
}
