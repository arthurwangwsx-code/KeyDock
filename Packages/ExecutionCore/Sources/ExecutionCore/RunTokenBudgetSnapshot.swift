import Foundation

/// 仅数字的运行事实，不携带授权、正文或可恢复会话。
public struct RunTokenBudgetSnapshot: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case awaitingUsage, verified, thresholdReached, usageUnavailable }
    public static let maximumThreshold = 1_000_000_000
    public static let currentPolicyVersion = 1
    public let policyVersion: Int
    public let maximumTokens: Int
    public let knownTokens: Int?
    public let completedTurns: Int
    public let status: Status
    public init(maximumTokens: Int, knownTokens: Int? = 0, completedTurns: Int = 0, status: Status = .awaitingUsage) {
        policyVersion = Self.currentPolicyVersion; self.maximumTokens = maximumTokens; self.knownTokens = knownTokens
        self.completedTurns = completedTurns; self.status = status
    }
    public var isValid: Bool {
        guard policyVersion == Self.currentPolicyVersion, (1...Self.maximumThreshold).contains(maximumTokens), (0...16).contains(completedTurns),
              knownTokens.map({ $0 >= 0 }) ?? true else { return false }
        if status == .usageUnavailable { return true }
        guard let knownTokens else { return false }
        if status == .awaitingUsage { return true }
        guard completedTurns > 0 else { return false }
        return status == .thresholdReached ? knownTokens >= maximumTokens : knownTokens < maximumTokens
    }
    private enum CodingKeys: String, CodingKey { case policyVersion, maximumTokens, knownTokens, completedTurns, status }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policyVersion = try c.decode(Int.self, forKey: .policyVersion)
        maximumTokens = try c.decode(Int.self, forKey: .maximumTokens)
        knownTokens = try c.decodeIfPresent(Int.self, forKey: .knownTokens)
        completedTurns = try c.decode(Int.self, forKey: .completedTurns)
        status = try c.decode(Status.self, forKey: .status)
        guard isValid else { throw CocoaError(.coderReadCorrupt) }
    }
    public func encode(to encoder: any Encoder) throws {
        guard isValid else { throw CocoaError(.coderInvalidValue) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(policyVersion, forKey: .policyVersion); try c.encode(maximumTokens, forKey: .maximumTokens)
        try c.encode(knownTokens, forKey: .knownTokens); try c.encode(completedTurns, forKey: .completedTurns)
        try c.encode(status, forKey: .status)
    }
}
