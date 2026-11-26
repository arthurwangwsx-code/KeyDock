import Foundation
import Testing
@testable import ExecutionCore

@Suite struct RunTokenReceiptTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Synthetic-TokenReceipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test(arguments: [false, true]) func numericBudgetUsesVersionThreeAndSurvivesReopen(typed: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try InvocationStore(directory: root), id = UUID()
        let definition = typed ? RunDefinitionReference(kind: .agent, definitionID: UUID(), definitionVersion: 1, fingerprint: String(repeating: "a", count: 64)) : nil
        let begun = try await store.begin(id: id, name: "Synthetic Agent", runDefinition: definition, runTokenBudget: .init(maximumTokens: 34))
        let budget = RunTokenBudgetSnapshot(maximumTokens: 34, knownTokens: 40, completedTurns: 2, status: .thresholdReached)
        await #expect(throws: InvocationStoreError.invalidMetadata) {
            try await store.finish(id: id, result: .init(state: .interrupted), runTokenBudget: .init(maximumTokens: 35), expectedRunStamp: begun.runStamp)
        }
        try await store.finish(id: id, result: .init(state: .interrupted, message: "ai.paused.tokens"), runTokenBudget: budget, expectedRunStamp: begun.runStamp)
        await store.releaseProtection(for: id, expectedRunStamp: begun.runStamp)
        let file = root.appendingPathComponent("invocations.json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["version"] as? Int == 3)
        let reopened = try InvocationStore(directory: root), rows = await reopened.list()
        #expect(rows.first?.runTokenBudget == budget && rows.first?.state == .interrupted)
        _ = try await reopened.clearRecordedRunTokenUsage()
        let cleared = await reopened.list()
        #expect(cleared.first?.runTokenBudget == .init(maximumTokens: 34, knownTokens: nil, completedTurns: 0, status: .usageUnavailable))
    }
    @Test(arguments: [1, 2], [false, true]) func budgetFieldNeverSneaksIntoLegacyEnvelope(version: Int, null: Bool) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(InvocationReceipt(id: UUID(), name: "Synthetic old", state: .succeeded))) as? [String: Any])
        row["runTokenBudget"] = null ? NSNull() : try JSONSerialization.jsonObject(with: JSONEncoder().encode(RunTokenBudgetSnapshot(maximumTokens: 34)))
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "receipts": [row]])
        let file = root.appendingPathComponent("invocations.json"); try data.write(to: file)
        #expect(throws: (any Error).self) { try InvocationStore(directory: root) }
        #expect(try Data(contentsOf: file) == data)
    }
    @Test func interruptedIntentKeepsOnlyUnknownFactsAndFreshRunStartsEmpty() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try InvocationStore(directory: root), first = UUID()
        try await store.begin(id: first, name: "Synthetic running", runTokenBudget: .init(maximumTokens: 34))
        let reopened = try InvocationStore(directory: root), old = try #require(await reopened.list().first)
        #expect(old.state == .interrupted && old.runTokenBudget?.status == .usageUnavailable)
        let next = try await reopened.begin(id: UUID(), name: "Synthetic fresh", runTokenBudget: .init(maximumTokens: 100))
        #expect(next.receipt.runTokenBudget == .init(maximumTokens: 100))
        _ = try await reopened.clearRecordedRunTokenUsage()
        let current = try #require(await reopened.list().first { $0.id == next.receipt.id })
        #expect(current.runTokenBudget == .init(maximumTokens: 100))
    }

    @Test func clearingCompletedRecoverySourceDoesNotResetNewAttemptOrInvalidateItsStamp() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try InvocationStore(directory: root), first = UUID(), second = UUID()
        let definition = RunDefinitionReference(kind: .agent, definitionID: UUID(), definitionVersion: 1, fingerprint: String(repeating: "b", count: 64))
        let source = try await store.begin(id: first, name: "Synthetic source", runDefinition: definition, runTokenBudget: .init(maximumTokens: 100))
        try await store.finish(id: first, result: .init(state: .succeeded), runTokenBudget: .init(maximumTokens: 100, knownTokens: 14, completedTurns: 1, status: .verified), expectedRunStamp: source.runStamp)
        await store.releaseProtection(for: first, expectedRunStamp: source.runStamp)
        let check = try await store.inspectRecovery(first)
        let next = try await store.begin(id: second, name: "Synthetic new attempt", runDefinition: definition, runTokenBudget: .init(maximumTokens: 200), recovering: check)
        let cleared = try await store.clearRecordedRunTokenUsage(), rows = await store.list()
        #expect(cleared == [first])
        #expect(rows.first { $0.id == first }?.runTokenBudget?.knownTokens == nil)
        #expect(rows.first { $0.id == second }?.runTokenBudget == .init(maximumTokens: 200))
        try await store.finish(id: second, result: .init(state: .succeeded), runTokenBudget: .init(maximumTokens: 200, knownTokens: 40, completedTurns: 2, status: .verified), expectedRunStamp: next.runStamp)
        #expect(await store.list().first { $0.id == second }?.state == .succeeded)
    }
}
