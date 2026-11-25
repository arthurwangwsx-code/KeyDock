import Foundation

public struct AICurrencyAmount: Equatable, Sendable {
    public let currency: String
    /// 精确十进制字符串，不通过Double或分片舍入。
    public let amount: String
    public init(currency: String, amount: String) { self.currency = currency; self.amount = amount }
}

public struct AICostSummary: Equatable, Sendable {
    public var amounts: [AICurrencyAmount] = []
    public var callCount = 0
    public var unpricedCalls = 0
    public var incompleteCalls = 0
    public var invalidCalls = 0
    public var overflowed = false
    public var scopeIncomplete = false
    public var noHistoricalSnapshot = false
    public var isComplete: Bool { callCount > 0 && !noHistoricalSnapshot && !overflowed && !scopeIncomplete && unpricedCalls == 0 && incompleteCalls == 0 && invalidCalls == 0 }
    public static let unknown = AICostSummary(noHistoricalSnapshot: true)

    public static func estimate(_ recorded: AIRecordedUsage?) -> Self {
        guard let recorded else { return .unknown }
        var result = Self(overflowed: recorded.overflowed, scopeIncomplete: recorded.incomplete)
        var totals: [String: Decimal] = [:], invalidCurrencies: Set<String> = [], seen: Set<UUID> = []
        for call in recorded.calls.prefix(128) {
            result.callCount += 1
            guard seen.insert(call.attemptID).inserted, AIServiceIdentity.isFingerprint(call.endpointFingerprint),
                  !call.model.isEmpty, call.model.utf8.count <= 256, call.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  call.finishedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= call.startedAt }) ?? true else { result.invalidCalls += 1; continue }
            let usage = call.usage
            let partial = call.hasUnknownUsage || call.outcome != .succeeded || call.finishedAt == nil || usage?.inputTokens == nil || usage?.outputTokens == nil
            if partial { result.incompleteCalls += 1 }
            guard !call.rateCorrupt else { result.invalidCalls += 1; continue }
            guard let snapshot = call.rate else { result.unpricedCalls += 1; continue }
            guard snapshot.isValid(endpointFingerprint: call.endpointFingerprint, model: call.model) else { result.invalidCalls += 1; continue }
            guard let usage else { continue }
            guard usage.attemptID == call.attemptID, usage.counting == .cumulative,
                  (usage.inputTokens ?? 0) >= 0, (usage.outputTokens ?? 0) >= 0 else { result.invalidCalls += 1; continue }
            let input = AIRateArithmetic.amount(tokens: usage.inputTokens, price: snapshot.rate.inputPerMillion)
            let output = AIRateArithmetic.amount(tokens: usage.outputTokens, price: snapshot.rate.outputPerMillion)
            guard usage.inputTokens == nil || input != nil, usage.outputTokens == nil || output != nil else { result.invalidCalls += 1; continue }
            guard input != nil || output != nil else { continue }
            let currency = snapshot.rate.currency
            guard !invalidCurrencies.contains(currency) else { continue }
            var subtotal = totals[currency]
            for amount in [input, output].compactMap({ $0 }) {
                if let previous = subtotal {
                    guard let sum = AIRateArithmetic.sum(previous, amount) else { invalidCurrencies.insert(currency); result.invalidCalls += 1; subtotal = nil; break }
                    subtotal = sum
                } else { subtotal = amount }
            }
            totals[currency] = subtotal
        }
        if recorded.calls.count > 128 { result.overflowed = true }
        result.amounts = totals.keys.sorted().compactMap { currency in
            guard !invalidCurrencies.contains(currency), let value = totals[currency] else { return nil }
            return AICurrencyAmount(currency: currency, amount: AIRateArithmetic.string(value))
        }
        return result
    }
}
