import Foundation
import Testing
@testable import AICore

@Suite struct AIRateTests {
    @Test(arguments: ["0", "0.0", "0.25", "2", "999999999.999999999", "0.000000000000000001", "2.000000000000000000", "1000000000"])
    func exactPrices(_ text: String) { #expect(AIRateArithmetic.price(text) != nil) }
    @Test(arguments: ["", " ", "1\n", "NaN", "Infinity", "1e-3", "-0", "+1", "01", ".1", "1.", "１", "1,000", "1000000000000000000", "0.0000000000000000001", "123456789.1234567891"])
    func invalidPrices(_ text: String) { #expect(AIRateArithmetic.price(text) == nil) }
    @Test func preciseArithmeticNeverRoundsTinyPositiveOrOverflowToZero() throws {
        let tiny = try #require(AIRateArithmetic.amount(tokens: 1, price: "0.000000000000000001"))
        #expect(tiny == Decimal(string: "0.000000000000000000000001"))
        #expect(AIRateArithmetic.string(tiny) != "0")
        #expect(AIRateArithmetic.amount(tokens: Int.max, price: "999999999.999999999") != nil)
        #expect(AIRateArithmetic.amount(tokens: nil, price: "0") == nil)
        #expect(AIRateArithmetic.amount(tokens: -1, price: "1") == nil)
        #expect(AIRateArithmetic.sum(Decimal(string: "1000000000000000000000000")!, tiny) == nil)
    }
    @Test func identityUsesWireEndpointAndExactModelBytes() {
        let url = URL(string: "https://example.com/a?tenant=one")!
        let rate = definition(url: url, model: "é")
        #expect(rate.matches(endpoint: url, model: "é"))
        #expect(!rate.matches(endpoint: url, model: "e\u{301}"))
        #expect(!rate.matches(endpoint: URL(string: "https://example.com/b?tenant=one")!, model: "é"))
        #expect(!rate.matches(endpoint: URL(string: "https://example.com/a?tenant=two")!, model: "é"))
        var other = rate; other.model = "e\u{301}"; #expect(other != rate)
        #expect(!rate.matches(endpoint: url, model: "É"))
        let config = AIProviderConfiguration(endpoint: url, model: "é")
        #expect(AIRateDefinition.snapshot(in: [rate, rate], configuration: config) == nil)
        other = rate; other.inputPerMillion = "bad"
        #expect(AIRateDefinition.snapshot(in: [rate, other], configuration: config) == nil)
        other.enabled = false
        #expect(AIRateDefinition.snapshot(in: [other], configuration: config) == nil)
    }
    @Test func cumulativeSnapshotCostsAreFrozenAndKnownZeroDiffersFromMissing() async throws {
        var rate = definition(), accumulator = AIUsageAccumulator()
        let recorder = AIUsageRecorder(rate: .init(rate: rate))
        rate.inputPerMillion = "999"
        let worker = try #require(recorder.beginWorker()), id = try #require(recorder.beginAttempt(worker: worker, configuration: configuration()))
        let usage = AIUsage(inputTokens: 1_000_000, outputTokens: 500_000, attemptID: id)
        try accumulator.observe(usage); recorder.observe(usage); recorder.observe(usage)
        recorder.finishAttempt(id, outcome: .succeeded); recorder.endWorker(worker)
        let recorded = await recorder.closeAndSnapshot(), cost = AICostSummary.estimate(recorded)
        #expect(recorded.calls.count == 1 && cost.isComplete && cost.amounts.first?.amount == "4")
        #expect(recorded.calls.first?.rate?.rate.inputPerMillion == "2")
        var missing = recorded; missing.calls[0].usage = nil
        #expect(AICostSummary.estimate(missing).amounts.isEmpty)
        var zero = recorded; zero.calls[0].usage = .init(inputTokens: 0, outputTokens: 0, attemptID: id)
        #expect(AICostSummary.estimate(zero).amounts.first?.amount == "0")
        var partial = recorded; partial.calls[0].usage?.outputTokens = nil
        let partialCost = AICostSummary.estimate(partial)
        #expect(!partialCost.isComplete && partialCost.amounts.first?.amount == "2")
        var cancelled = recorded; cancelled.calls[0].outcome = .cancelled
        #expect(!AICostSummary.estimate(cancelled).isComplete && AICostSummary.estimate(cancelled).amounts.first?.amount == "4")
    }
    @Test func corruptedHistoricalRateKeepsValidTokenFacts() async throws {
        let recorder = AIUsageRecorder(rate: .init(rate: definition()))
        let worker = try #require(recorder.beginWorker()), id = try #require(recorder.beginAttempt(worker: worker, configuration: configuration()))
        recorder.observe(.init(inputTokens: 12, outputTokens: 3, attemptID: id)); recorder.finishAttempt(id, outcome: .succeeded); recorder.endWorker(worker)
        let recorded = await recorder.closeAndSnapshot()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recorded)) as? [String: Any])
        var calls = try #require(object["calls"] as? [[String: Any]]); calls[0]["rate"] = ["unexpected": true]; object["calls"] = calls
        let decoded = try JSONDecoder().decode(AIRecordedUsage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.calls.first?.usage?.inputTokens == 12 && decoded.calls.first?.rateCorrupt == true)
        #expect(AICostSummary.estimate(decoded).amounts.isEmpty && AICostSummary.estimate(decoded).invalidCalls == 1)
    }
    private func configuration() -> AIProviderConfiguration { .init(endpoint: URL(string: "https://example.com/synthetic")!, model: "synthetic-model") }
    private func definition(url: URL = URL(string: "https://example.com/synthetic")!, model: String = "synthetic-model") -> AIRateDefinition {
        .init(endpointFingerprint: AIServiceIdentity.fingerprint(url), model: model, currency: "USD", inputPerMillion: "2", outputPerMillion: "4")
    }
}
