import Foundation
import Testing
import ExecutionCore

@Suite struct TerminalIntentRecoveryTests {
    @Test func interruptedTerminalIntentIsRestoredAsUnknownWithoutReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Terminal-Intent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try InvocationStore(directory: directory), id = UUID()
        try await first.begin(id: id, name: "Synthetic terminal", initialMessage: "terminal.handoffIntent")
        let restored = try InvocationStore(directory: directory)
        let receipt = try #require(await restored.list().first { $0.id == id })
        #expect(receipt.state == .interrupted && receipt.message == "terminal.handoffUnknown")
        try await restored.finish(id: id, result: .init(state: .succeeded, message: "terminal.handedOff"))
        #expect(await restored.list().first { $0.id == id }?.message == "terminal.handoffUnknown")
    }
}
