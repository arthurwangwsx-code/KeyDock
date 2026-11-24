import Foundation

public enum CommandCollectionValidationError: Error, Sendable, Equatable {
    case invalidName, nameTooLong, tooManyCommands, invalidCommandID, duplicateCommandID
}

/// 有序、唯一的快捷动作引用；不是工作流，没有批量执行或隐式授权语义。
public struct CommandCollection: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let commandIDs: [String]
    public init(id: UUID = UUID(), name: String, commandIDs: [String] = []) throws {
        guard name.utf8.prefix(201).count <= 200 else { throw CommandCollectionValidationError.nameTooLong }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CommandCollectionValidationError.invalidName
        }
        self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines); self.commandIDs = commandIDs
        try validate()
    }
    public func validate() throws {
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CommandCollectionValidationError.invalidName
        }
        guard name.utf8.prefix(201).count <= 200 else { throw CommandCollectionValidationError.nameTooLong }
        guard commandIDs.count <= 32 else { throw CommandCollectionValidationError.tooManyCommands }
        for id in commandIDs {
            guard Self.validReference(id) else { throw CommandCollectionValidationError.invalidCommandID }
        }
        guard Set(commandIDs).count == commandIDs.count else { throw CommandCollectionValidationError.duplicateCommandID }
    }
    private static func validReference(_ id: String) -> Bool {
        guard id.utf8.prefix(513).count <= 512, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let parts = id.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        // app ID含原始路径；其他命令引用遵循现有descriptor的命名空间规则。
        func validPart(_ value: Substring) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
            }
        }
        guard validPart(parts[0]) else { return false }
        if parts[0] == "app", parts[1].hasPrefix("/") { return true }
        return id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(validPart)
    }
    private enum CodingKeys: String, CodingKey { case id, name, commandIDs }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var references = try values.nestedUnkeyedContainer(forKey: .commandIDs)
        if let count = references.count, count > 32 { throw CommandCollectionValidationError.tooManyCommands }
        var ids: [String] = []
        while !references.isAtEnd {
            guard ids.count < 32 else { throw CommandCollectionValidationError.tooManyCommands }
            ids.append(try references.decode(String.self))
        }
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name), commandIDs: ids)
    }
}
