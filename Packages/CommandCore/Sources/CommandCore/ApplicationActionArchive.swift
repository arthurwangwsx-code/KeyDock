import Foundation

/// 旧独立文件的只读迁移格式；当前canonical定义与偏好一起保存在主配置v3。
public struct ApplicationActionArchive: Codable, Sendable {
    public static let maximumActions = 100
    public static let maximumBytes = 1_048_576
    public let schemaVersion: Int
    public let actions: [SavedApplicationAction]
    public init(actions: [SavedApplicationAction]) throws {
        guard actions.count <= Self.maximumActions, Set(actions.map(\.id)).count == actions.count else {
            throw DesktopActionValidationError.invalidDefinition
        }
        schemaVersion = 1; self.actions = actions
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw DesktopActionValidationError.invalidDefinition }
        return data
    }
    public static func decode(_ data: Data) throws -> ApplicationActionArchive {
        guard data.count <= maximumBytes else { throw DesktopActionValidationError.invalidDefinition }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, actions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw DesktopActionValidationError.invalidDefinition }
        try self.init(actions: c.decode([SavedApplicationAction].self, forKey: .actions))
    }
}
