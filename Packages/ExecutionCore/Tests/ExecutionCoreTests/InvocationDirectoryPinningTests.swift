import Foundation
import Testing
@testable import ExecutionCore

@Suite struct InvocationDirectoryPinningTests {
    private struct Archive: Decodable { let version: Int; let receipts: [InvocationReceipt] }

    @Test func renamedDirectoryRemainsPinnedAfterOriginalPathBecomesSymbolicLink() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("KeyDock-Synthetic-Pinned-" + UUID().uuidString)
        defer { try? manager.removeItem(at: base) }
        let original = base.appendingPathComponent("original"), moved = base.appendingPathComponent("moved")
        let outside = base.appendingPathComponent("outside-owned")
        try manager.createDirectory(at: original, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("invocations.json")
        let sentinelBytes = Data("Synthetic outside sentinel; never valid invocation data".utf8)
        try sentinelBytes.write(to: sentinel)
        let store = try InvocationStore(directory: original)
        try manager.moveItem(at: original, to: moved)
        try manager.createSymbolicLink(at: original, withDestinationURL: outside)
        let id = UUID()
        try await store.begin(id: id, name: "Synthetic pinned invocation")
        try await store.finish(id: id, result: .init(state: .succeeded, message: "synthetic.finished"))
        let actual = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: moved.appendingPathComponent("invocations.json")))
        #expect(actual.version == 1 && actual.receipts.count == 1)
        #expect(actual.receipts.first?.id == id && actual.receipts.first?.state == .succeeded)
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(try manager.contentsOfDirectory(atPath: outside.path) == ["invocations.json"])
        #expect(try manager.contentsOfDirectory(atPath: moved.path) == ["invocations.json"])
        #expect(try manager.destinationOfSymbolicLink(atPath: original.path) == outside.path)
    }
}
