import Foundation

public enum WebActionValidationError: Error, Sendable, Equatable {
    case invalidName, nameTooLong, urlTooLong, invalidURL, unsupportedScheme, invalidHost
    case credentialsNotAllowed, controlCharacters, invalidPlaceholder, missingQuery, unexpectedQuery, queryTooLong
}

/// 只构造URL数据；不会联网、打开浏览器或将模型输出当作授权。
public struct WebActionDefinition: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let urlTemplate: String
    public var requiresQuery: Bool { urlTemplate.contains("{query}") }

    public init(id: UUID = UUID(), name: String, urlTemplate: String) throws {
        guard name.utf8.prefix(201).count <= 200 else { throw WebActionValidationError.nameTooLong }
        self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlTemplate = urlTemplate
        guard !Self.hasControl(name) else { throw WebActionValidationError.invalidName }
        try validate()
    }
    public func validate() throws {
        guard !name.isEmpty, !Self.hasControl(name) else { throw WebActionValidationError.invalidName }
        guard name.utf8.prefix(201).count <= 200 else { throw WebActionValidationError.nameTooLong }
        guard urlTemplate.utf8.prefix(4_097).count <= 4_096 else { throw WebActionValidationError.urlTooLong }
        let pieces = urlTemplate.components(separatedBy: "{query}")
        guard pieces.count <= 2 else { throw WebActionValidationError.invalidPlaceholder }
        var checked = urlTemplate
        if pieces.count == 2 {
            guard let token = urlTemplate.range(of: "{query}"), let question = urlTemplate.firstIndex(of: "?"),
                  token.lowerBound > question,
                  urlTemplate.firstIndex(of: "#").map({ token.upperBound <= $0 }) ?? true else {
                throw WebActionValidationError.invalidPlaceholder
            }
            checked = checked.replacingOccurrences(of: "{query}", with: "keydockquery")
        }
        guard !checked.contains("{"), !checked.contains("}") else { throw WebActionValidationError.invalidPlaceholder }
        _ = try Self.parseURL(checked)
    }
    public func resolvedURL(query: String? = nil) throws -> URL {
        try validate()
        guard requiresQuery else {
            guard query == nil else { throw WebActionValidationError.unexpectedQuery }
            return try Self.parseURL(urlTemplate)
        }
        guard let query, !query.isEmpty else { throw WebActionValidationError.missingQuery }
        guard query.utf8.prefix(1_025).count <= 1_024 else { throw WebActionValidationError.queryTooLong }
        guard !Self.hasControl(query) else { throw WebActionValidationError.controlCharacters }
        // 不使用urlQueryAllowed：其中的&、=、+等仍会改变查询语义。
        let encoded = query.utf8.map { byte -> String in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45,46,95,126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", Int(byte))
        }.joined()
        return try Self.parseURL(urlTemplate.replacingOccurrences(of: "{query}", with: encoded))
    }
    private enum CodingKeys: String, CodingKey { case id, name, urlTemplate }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
            urlTemplate: values.decode(String.self, forKey: .urlTemplate))
    }
    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func parseURL(_ text: String) throws -> URL {
        guard text.utf8.prefix(8_193).count <= 8_192 else { throw WebActionValidationError.urlTooLong }
        guard !hasControl(text) else { throw WebActionValidationError.controlCharacters }
        guard !text.isEmpty, !text.contains("\\"), !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              !text.contains("{"), !text.contains("}") else { throw WebActionValidationError.invalidURL }
        let bytes = Array(text.utf8)
        var index = 0
        func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index+1]), hex(bytes[index+2]) else { throw WebActionValidationError.invalidURL }
                index += 3
            } else { index += 1 }
        }
        guard let decoded = text.removingPercentEncoding else { throw WebActionValidationError.invalidURL }
        guard !hasControl(decoded) else { throw WebActionValidationError.controlCharacters }
        guard let delimiter = text.range(of: "://") else { throw WebActionValidationError.invalidURL }
        let scheme = text[..<delimiter.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { throw WebActionValidationError.unsupportedScheme }
        let rest = text[delimiter.upperBound...]
        let authority = String(rest.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
        guard !authority.contains("@") else { throw WebActionValidationError.credentialsNotAllowed }
        let hostAndPort = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = hostAndPort.first, validHost(String(first)) else { throw WebActionValidationError.invalidHost }
        if hostAndPort.count == 2 {
            let port = hostAndPort[1]
            guard (1...5).contains(port.utf8.count), port.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(port), (1...65_535).contains(value) else { throw WebActionValidationError.invalidURL }
        }
        guard let components = URLComponents(string: text), components.user == nil, components.password == nil,
              components.host?.lowercased() == first.lowercased(),
              let url = URL(string: text, encodingInvalidCharacters: false) else { throw WebActionValidationError.invalidURL }
        return url
    }
    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" && label.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
        }) else { return false }
        // 数字主机只接受四段十进制IPv4，拒绝整数/八进制等有歧义形式。
        let last = String(labels.last ?? "").lowercased()
        let numericLast = last.utf8.allSatisfy { (48...57).contains($0) } ||
            (last.hasPrefix("0x") && last.dropFirst(2).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        if numericLast {
            return labels.count == 4 && labels.allSatisfy { label in
                (label.count == 1 || label.first != "0") && Int(label).map({ (0...255).contains($0) }) == true
            }
        }
        return true
    }
}
