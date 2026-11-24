import Foundation
import Testing
@testable import MacAdapters

@Suite(.serialized) @MainActor struct PrivateArchiveStoreTests {
    @Test(arguments: [false, true]) func oversizedEncodingDoesNotCreateAFalseRecoveryOrDisableWrites(hasFile: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ArchiveBudget-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PrivateArchiveStore<Data>(directory: directory, fileName: "synthetic.json", transactionPrefix: ".synthetic-transaction-", maximumBytes: 8, empty: Data(), decode: { $0 }, encode: { $0 })
        let file = directory.appendingPathComponent("synthetic.json"), initial = Data([1,2,3])
        if hasFile { try store.save(initial) }
        #expect(throws: ArchiveStoreError.unavailable) { try store.save(Data(repeating: 1, count: 9)) }
        #expect(store.writable && store.preservedFiles.isEmpty)
        #expect(store.value == (hasFile ? initial : Data()))
        #expect((try? Data(contentsOf: file)) == (hasFile ? initial : nil))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".synthetic-transaction-") }.isEmpty)
        try store.save(Data([4]))
        #expect(store.value == Data([4]))
        #expect(try Data(contentsOf: file) == Data([4]))
    }
}
