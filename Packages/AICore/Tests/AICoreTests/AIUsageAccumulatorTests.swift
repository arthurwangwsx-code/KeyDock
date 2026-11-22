import Foundation
import Testing
import AICore

@Test func usageIdentityCanBeEnrichedWithoutDuplicatingRequest() throws {
    let attempt = UUID()
    var ledger = AIUsageAccumulator()
    #expect(try ledger.observe(.init(inputTokens: 12, outputTokens: nil, attemptID: attempt)) == .inserted)
    #expect(ledger.hasUnknownUsage)
    #expect(try ledger.observe(.init(inputTokens: nil, outputTokens: 4, attemptID: attempt, responseID: "response-a")) == .updated)
    #expect(ledger.observations.count == 1)
    #expect(ledger.observations.first?.inputTokens == 12)
    #expect(ledger.observations.first?.outputTokens == 4)
    #expect(ledger.observations.first?.responseID == "response-a")
    #expect(!ledger.hasUnknownUsage)
}

@Test func cumulativeMissingValuesAndDuplicateSnapshotsDoNotEraseKnownTokens() throws {
    let attempt = UUID()
    var ledger = AIUsageAccumulator()
    _ = try ledger.observe(.init(inputTokens: 12, outputTokens: 4, attemptID: attempt, responseID: "response-a"))
    #expect(try ledger.observe(.init(inputTokens: nil, outputTokens: nil, attemptID: attempt)) == .duplicate)
    #expect(try ledger.observe(.init(inputTokens: 12, outputTokens: 4, attemptID: attempt, responseID: "response-a")) == .duplicate)
    #expect(ledger.observations == [.init(inputTokens: 12, outputTokens: 4, attemptID: attempt, responseID: "response-a")])
}

@Test func retryAttemptsRemainSeparateEvenWithSameProviderResponseID() throws {
    let first = UUID(), retry = UUID()
    var ledger = AIUsageAccumulator()
    _ = try ledger.observe(.init(inputTokens: 12, outputTokens: 4, attemptID: first, responseID: "provider-id"))
    _ = try ledger.observe(.init(inputTokens: 13, outputTokens: 5, attemptID: retry, responseID: "provider-id"))
    #expect(ledger.observations.map(\.attemptID) == [first, retry])
    #expect(ledger.observations.compactMap(\.outputTokens) == [4, 5])
}

@Test func conflictingProviderIdentityCannotMergeCountsIntoAnotherResponse() throws {
    let attempt = UUID()
    var ledger = AIUsageAccumulator()
    _ = try ledger.observe(.init(inputTokens: 12, outputTokens: 4, attemptID: attempt, responseID: "response-a"))
    #expect(throws: AIUsageAccumulatorError.conflictingResponseIdentity) {
        _ = try ledger.observe(.init(inputTokens: 400, outputTokens: 900, attemptID: attempt, responseID: "response-b"))
    }
    #expect(ledger.observations.first?.inputTokens == 12)
    #expect(ledger.observations.first?.outputTokens == 4)
    #expect(ledger.unknownAttempts == [attempt])
}

@Test func deltaIsExplicitlyRejectedAndMarkedUnknownRatherThanDoubleCounted() throws {
    let attempt = UUID()
    var ledger = AIUsageAccumulator()
    _ = try ledger.observe(.init(inputTokens: 12, outputTokens: 4, attemptID: attempt))
    let delta = AIUsage(inputTokens: nil, outputTokens: 3, attemptID: attempt, counting: .delta)
    #expect(throws: AIUsageAccumulatorError.unsupportedDelta) { _ = try ledger.observe(delta) }
    #expect(throws: AIUsageAccumulatorError.unsupportedDelta) { _ = try ledger.observe(delta) }
    #expect(ledger.observations.first?.outputTokens == 4)
    #expect(ledger.hasUnknownUsage)
}

@Test func unknownAndCancelledUsageRetainsPartialEvidenceWithoutInventingZero() throws {
    let attempt = UUID(), noUsage = UUID()
    var ledger = AIUsageAccumulator()
    _ = try ledger.observe(.init(inputTokens: nil, outputTokens: 3, attemptID: attempt))
    ledger.markUnknown(attemptID: attempt)
    ledger.markUnknown(attemptID: noUsage)
    #expect(ledger.observations.first?.inputTokens == nil)
    #expect(ledger.observations.first?.outputTokens == 3)
    #expect(ledger.unknownAttempts == [attempt, noUsage])
}

@Test func regressiveSnapshotPreservesKnownLowerBoundAndFlagsUncertainty() throws {
    let attempt = UUID()
    var ledger = AIUsageAccumulator()
    _ = try ledger.observe(.init(inputTokens: 12, outputTokens: 4, attemptID: attempt))
    _ = try ledger.observe(.init(inputTokens: 11, outputTokens: 8, attemptID: attempt))
    #expect(ledger.observations.first?.inputTokens == 12)
    #expect(ledger.observations.first?.outputTokens == 8)
    #expect(ledger.hasUnknownUsage)
}

@Test func invalidTokenCountsDoNotEnterUsageLedger() throws {
    let attempt = UUID()
    var ledger = AIUsageAccumulator()
    #expect(throws: AIUsageAccumulatorError.invalidTokenCount) {
        _ = try ledger.observe(.init(inputTokens: -1, outputTokens: 4, attemptID: attempt))
    }
    #expect(ledger.observations.isEmpty)
    #expect(ledger.unknownAttempts == [attempt])
}
