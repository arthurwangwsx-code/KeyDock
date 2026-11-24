import Foundation
import Testing
import CommandCore
@testable import MacAdapters

private enum AppStoreInjectedFailure: Error { case synthetic }

@Suite(.serialized) @MainActor
struct ApplicationActionStoreTransactionTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-App-Store-Proposal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func action(_ name: String) throws -> SavedApplicationAction {
        try SavedApplicationAction(name: name, applicationID: "app./Applications/Synthetic.app", behavior: .show)
    }
    private func raw(_ value: SavedApplicationAction) throws -> Data {
        var data = try ApplicationActionArchive(actions: [value]).encoded()
        data.append(10) // 补偿必须保留原始字节，不能重新编码代替。
        return data
    }
    private func file(_ root: URL) -> URL { root.appendingPathComponent("application-actions.json") }
    private func recoveries(_ root: URL) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".application-actions-transaction-") }
            .map { try Data(contentsOf: $0) }
    }

    @Test func initialCommitAndExchangeRoundTripAreReloadable() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try action("First"), second = try action("Second")
        let store = try ApplicationActionStore(directory: root)
        try store.save([first]); try store.save([second])
        #expect(store.writable && store.actions == [second])
        #expect(try ApplicationActionStore(directory: root).actions == [second])
        #expect(try recoveries(root).isEmpty)
    }

    @Test func newExternalFileAfterPreflightCannotBeClobberedByFirstSave() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let external = try raw(action("External")), candidate = try action("Candidate")
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .beforeCommit { try PrivateFiles.write(external, to: file(root)) }
        })
        #expect(throws: ApplicationActionStoreError.externalChange) { try store.save([candidate]) }
        #expect(try Data(contentsOf: file(root)) == external)
        #expect(!store.writable && store.actions.isEmpty)
        #expect(try recoveries(root).isEmpty)
    }

    @Test func changedFileAfterPreflightIsSwappedBackAndNeverDeleted() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try action("Original"), external = try raw(action("External"))
        let originalBytes = try raw(original)
        try PrivateFiles.write(originalBytes, to: file(root))
        var compensationSynced = false
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .beforeCommit { try PrivateFiles.write(external, to: file(root)) }
            if stage == .beforeCompensationDirectorySync { compensationSynced = true }
        })
        #expect(throws: ApplicationActionStoreError.externalChange) { try store.save([action("Candidate")]) }
        #expect(try Data(contentsOf: file(root)) == external)
        #expect(store.actions == [original] && !store.writable && compensationSynced)
        #expect(try recoveries(root).isEmpty)
    }

    @Test func postCommitExternalFileStaysFinalAndOriginalBackupIsPreserved() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try action("Original"), originalBytes = try raw(original), external = try raw(action("External"))
        try PrivateFiles.write(originalBytes, to: file(root))
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .afterCommit { try PrivateFiles.write(external, to: file(root)) }
        })
        #expect(throws: ApplicationActionStoreError.rollbackIncomplete) { try store.save([action("Candidate")]) }
        #expect(try Data(contentsOf: file(root)) == external)
        #expect(try recoveries(root).contains(originalBytes))
        #expect(!store.writable && store.actions == [original] && !store.preservedFiles.isEmpty)
    }

    @Test func errorAfterExchangeRestoresExactOriginalAndAllowsRetry() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try action("Original"), originalBytes = try raw(original)
        try PrivateFiles.write(originalBytes, to: file(root))
        var injected = false, compensationSyncReached = false
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .afterCommit && !injected { injected = true; throw AppStoreInjectedFailure.synthetic }
            if stage == .beforeCompensationDirectorySync { compensationSyncReached = true }
        })
        #expect(throws: AppStoreInjectedFailure.self) { try store.save([action("Candidate")]) }
        #expect(try Data(contentsOf: file(root)) == originalBytes)
        #expect(store.actions == [original] && store.writable && compensationSyncReached)
        #expect(try recoveries(root).isEmpty)
        let retry = try action("Explicit retry")
        try store.save([retry]); #expect(store.actions == [retry])
    }

    @Test func firstCommitFailureCompensatesToAbsenceWithoutLeavingCandidate() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var syncReached = false
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .afterCommit { throw AppStoreInjectedFailure.synthetic }
            if stage == .beforeCompensationDirectorySync { syncReached = true }
        })
        #expect(throws: AppStoreInjectedFailure.self) { try store.save([action("Candidate")]) }
        #expect(!FileManager.default.fileExists(atPath: file(root).path))
        #expect(store.writable && store.actions.isEmpty && syncReached)
        #expect(try recoveries(root).isEmpty)
    }

    @Test func failedCompensationSyncKeepsEvidenceAndDisablesWrites() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try action("Original"), originalBytes = try raw(original)
        try PrivateFiles.write(originalBytes, to: file(root))
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .afterCommit || stage == .beforeCompensationDirectorySync { throw AppStoreInjectedFailure.synthetic }
        })
        #expect(throws: ApplicationActionStoreError.rollbackIncomplete) { try store.save([action("Candidate")]) }
        #expect(try Data(contentsOf: file(root)) == originalBytes)
        #expect(!store.writable && store.actions == [original] && !store.preservedFiles.isEmpty)
        #expect(throws: ApplicationActionStoreError.unavailable) { try store.save([action("Second")]) }
    }

    @Test func externalEditDuringCompensationIsPutBackAndBothVersionsSurvive() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try action("Original"), originalBytes = try raw(original), external = try raw(action("External"))
        try PrivateFiles.write(originalBytes, to: file(root))
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .afterCommit { throw AppStoreInjectedFailure.synthetic }
            if stage == .beforeCompensation { try PrivateFiles.write(external, to: file(root)) }
        })
        #expect(throws: ApplicationActionStoreError.rollbackIncomplete) { try store.save([action("Candidate")]) }
        #expect(try Data(contentsOf: file(root)) == external)
        #expect(try recoveries(root).contains(originalBytes))
        #expect(!store.writable && store.actions == [original])
    }

    @Test func replacementDirectoryWithIdenticalBytesIsNotTreatedAsOwned() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live"), moved = root.appendingPathComponent("moved")
        let original = try action("Original"), originalBytes = try raw(original)
        try PrivateFiles.write(originalBytes, to: file(live))
        let store = try ApplicationActionStore(directory: live)
        try FileManager.default.moveItem(at: live, to: moved)
        try PrivateFiles.write(originalBytes, to: file(live))
        #expect(throws: ApplicationActionStoreError.externalChange) { try store.save([action("Candidate")]) }
        #expect(try Data(contentsOf: file(live)) == originalBytes)
        #expect(try Data(contentsOf: file(moved)) == originalBytes)
        #expect(!store.writable && store.actions == [original])
    }

    @Test func directoryReplacementAfterStagingNeverWritesIntoTheReplacement() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live"), moved = root.appendingPathComponent("moved")
        let original = try action("Original"), originalBytes = try raw(original), external = try raw(action("External directory"))
        try PrivateFiles.write(originalBytes, to: file(live))
        let store = try ApplicationActionStore(directory: live, faultHook: { stage in
            if stage == .afterCandidateFileSync {
                try FileManager.default.moveItem(at: live, to: moved)
                try PrivateFiles.write(external, to: file(live))
            }
        })
        #expect(throws: ApplicationActionStoreError.externalChange) { try store.save([action("Candidate")]) }
        #expect(try Data(contentsOf: file(live)) == external)
        #expect(try Data(contentsOf: file(moved)) == originalBytes)
        #expect(try recoveries(moved).isEmpty)
        #expect(!store.writable && store.actions == [original])
    }

    @Test func symlinkArrivingAtCommitIsRestoredWithoutReadingOrChangingItsTarget() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try action("Original"), originalBytes = try raw(original)
        let unrelated = root.appendingPathComponent("synthetic-unrelated.txt"), untouched = Data("Synthetic unrelated bytes".utf8)
        try PrivateFiles.write(originalBytes, to: file(root)); try untouched.write(to: unrelated)
        let store = try ApplicationActionStore(directory: root, faultHook: { stage in
            if stage == .beforeCommit {
                try FileManager.default.removeItem(at: file(root))
                try FileManager.default.createSymbolicLink(at: file(root), withDestinationURL: unrelated)
            }
        })
        #expect(throws: ApplicationActionStoreError.externalChange) { try store.save([action("Candidate")]) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file(root).path) == unrelated.path)
        #expect(try Data(contentsOf: unrelated) == untouched)
        #expect(!store.writable && store.actions == [original])
    }

    @Test func restartWithTransactionResidueListsNamesAndDoesNotDecodeAnyCandidate() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let orphan = ".application-actions-transaction-" + UUID().uuidString
        let raw = Data("Synthetic undecodable recovery bytes".utf8)
        try raw.write(to: root.appendingPathComponent(orphan))
        try raw.write(to: file(root)) // 有残留时连final也不解码，不能把它当作确认的新配置。
        let store = try ApplicationActionStore(directory: root)
        #expect(!store.writable && store.actions.isEmpty)
        #expect(store.preservedFiles == [orphan, "application-actions.json"])
        #expect(!store.recoveryFilesMayBeTruncated)
        #expect(try Data(contentsOf: root.appendingPathComponent(orphan)) == raw)
        #expect(try Data(contentsOf: file(root)) == raw)
        #expect(throws: ApplicationActionStoreError.unavailable) { try store.save([action("Candidate")]) }
    }

    @Test func recoveryFilenameListingIsBoundedAndDoesNotDeleteOtherEntries() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<35 {
            try Data("Synthetic".utf8).write(to: root.appendingPathComponent(".application-actions-transaction-\(index)"))
        }
        let store = try ApplicationActionStore(directory: root)
        #expect(!store.writable && store.actions.isEmpty)
        #expect(store.preservedFiles.count == 32 && store.recoveryFilesMayBeTruncated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 35)
    }
}
