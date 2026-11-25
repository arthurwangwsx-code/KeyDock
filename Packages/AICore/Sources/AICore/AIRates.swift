import Foundation
import CryptoKit

/// 费率绑定准确请求身份，不把可能含query的完整endpoint写入用量元数据。
public enum AIServiceIdentity {
    public static func fingerprint(_ endpoint: URL) -> String {
        SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct AIRateDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var revision: UUID
    public var endpointFingerprint: String
    public var model: String
    public var currency: String
    public var inputPerMillion: String
    public var outputPerMillion: String
    public var enabled: Bool
    public init(id: UUID = UUID(), revision: UUID = UUID(), endpointFingerprint: String, model: String,
                currency: String, inputPerMillion: String, outputPerMillion: String, enabled: Bool = true) {
        self.id = id; self.revision = revision; self.endpointFingerprint = endpointFingerprint; self.model = model
        self.currency = currency; self.inputPerMillion = inputPerMillion; self.outputPerMillion = outputPerMillion; self.enabled = enabled
    }
    public var isValid: Bool {
        AIServiceIdentity.isFingerprint(endpointFingerprint) && model.utf8.count <= 256 && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        currency.utf8.count == 3 && currency.utf8.allSatisfy { (65...90).contains($0) } &&
        AIRateArithmetic.price(inputPerMillion) != nil && AIRateArithmetic.price(outputPerMillion) != nil
    }
    public func matches(endpoint: URL, model: String) -> Bool {
        enabled && isValid && endpointFingerprint == AIServiceIdentity.fingerprint(endpoint) && self.model.utf8.elementsEqual(model.utf8)
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.revision == b.revision && a.endpointFingerprint == b.endpointFingerprint &&
        a.model.utf8.elementsEqual(b.model.utf8) && a.currency == b.currency && a.inputPerMillion == b.inputPerMillion &&
        a.outputPerMillion == b.outputPerMillion && a.enabled == b.enabled
    }
    public static func snapshot(in definitions: [Self], configuration: AIProviderConfiguration, at date: Date = Date()) -> AIRateSnapshot? {
        guard definitions.count <= 64 else { return nil }
        let matching = definitions.filter { $0.enabled && $0.endpointFingerprint == AIServiceIdentity.fingerprint(configuration.endpoint) && $0.model.utf8.elementsEqual(configuration.model.utf8) }
        guard matching.count == 1, matching[0].isValid else { return nil }
        return .init(rate: matching[0], frozenAt: date)
    }
}

public struct AIRateSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let unitTokens: Int
    public let source: String
    public let rate: AIRateDefinition
    public let frozenAt: Date
    public init(rate: AIRateDefinition, frozenAt: Date = Date()) {
        schemaVersion = 1; unitTokens = 1_000_000; source = "userProvided"; self.rate = rate; self.frozenAt = frozenAt
    }
    public func isValid(endpointFingerprint: String, model: String) -> Bool {
        schemaVersion == 1 && unitTokens == 1_000_000 && source == "userProvided" && rate.isValid && rate.enabled && frozenAt.timeIntervalSinceReferenceDate.isFinite &&
        rate.endpointFingerprint == endpointFingerprint && rate.model.utf8.elementsEqual(model.utf8)
    }
}

/// 单价最多18位小数和18位有效数字；任何算术错误保持未知。
public enum AIRateArithmetic {
    public static func price(_ text: String) -> Decimal? {
        guard text.utf8.count <= 37 else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let integer = parts.first, !integer.isEmpty,
              integer.utf8.count <= 18, (integer == "0" || integer.first != "0"),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              (parts.count == 1 || parts[1].utf8.count <= 18) else { return nil }
        var canonical = text
        if parts.count == 2 {
            while canonical.last == "0" { canonical.removeLast() }
            if canonical.last == "." { canonical.removeLast() }
        }
        guard canonical.utf8.filter({ $0 != 46 }).drop(while: { $0 == 48 }).count <= 18,
              let value = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
    public static func amount(tokens: Int?, price: String) -> Decimal? {
        guard let tokens, tokens >= 0, var price = self.price(price) else { return nil }
        var count = Decimal(tokens), product = Decimal(), unit = Decimal(1_000_000), result = Decimal()
        guard NSDecimalMultiply(&product, &count, &price, .plain) == .noError,
              NSDecimalDivide(&result, &product, &unit, .plain) == .noError, !result.isNaN,
              tokens == 0 || price == 0 || result > 0 else { return nil }
        return result
    }
    public static func sum(_ left: Decimal, _ right: Decimal) -> Decimal? {
        var a = left, b = right, value = Decimal()
        guard NSDecimalAdd(&value, &a, &b, .plain) == .noError, !value.isNaN else { return nil }
        return value
    }
    public static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
}
