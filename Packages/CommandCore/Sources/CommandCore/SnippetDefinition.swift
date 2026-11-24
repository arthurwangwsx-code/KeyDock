import Foundation

public enum SnippetValidationError: Error, Sendable, Equatable {
    case emptyName, invalidName, nameTooLong, emptyText, invalidText, textTooLong
}
/// 显式保存的文本配置，不是剪贴板采集；不支持自动键盘监听或隐式模板执行。
public struct SnippetDefinition: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let text: String
    public init(id: UUID = UUID(), name: String, text: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SnippetValidationError.emptyName }
        guard name.utf8.count <= 200 else { throw SnippetValidationError.nameTooLong }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SnippetValidationError.invalidName }
        guard !text.isEmpty else { throw SnippetValidationError.emptyText }
        guard text.utf8.count <= 65_536 else { throw SnippetValidationError.textTooLong }
        guard !text.utf8.contains(0) else { throw SnippetValidationError.invalidText }
        self.id = id; self.name = name; self.text = text
    }
    private enum CodingKeys: String, CodingKey { case id, name, text }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name), text: values.decode(String.self, forKey: .text))
    }
}
