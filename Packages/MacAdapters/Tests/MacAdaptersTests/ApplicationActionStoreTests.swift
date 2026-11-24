import Foundation
import Testing
import CommandCore
@testable import MacAdapters

@Suite(.serialized) @MainActor
struct ApplicationActionStoreTests {
    private func action(_ name: String) throws -> SavedApplicationAction {
        try SavedApplicationAction(name: name, applicationID: "app./Applications/Synthetic.app", behavior: .show)
    }
    @Test func independentArchiveSurvivesAnOldBaseConfigurationRewrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-App-Actions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ApplicationActionStore(directory: directory), value = try action("Synthetic")
        try store.save([value])
        let bytes = try Data(contentsOf: directory.appendingPathComponent("application-actions.json"))
        try PrivateFiles.write(Data("{\"schemaVersion\":1,\"language\":\"en\"}".utf8), to: directory.appendingPathComponent("configuration.json"))
        #expect(try Data(contentsOf: directory.appendingPathComponent("application-actions.json")) == bytes)
        #expect(try ApplicationActionStore(directory: directory).actions == [value])
    }
    @Test func aPostRenameErrorRestoresExactOriginalBytesAndMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-App-Actions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try action("Original"), candidate = try action("Candidate")
        let file = directory.appendingPathComponent("application-actions.json")
        var raw = try ApplicationActionArchive(actions: [original]).encoded(); raw.append(10)
        try PrivateFiles.write(raw, to: file)
        let store = try ApplicationActionStore(directory: directory, faultHook: { stage in
            if stage == .afterCommit { throw CocoaError(.fileWriteUnknown) }
        })
        #expect(throws: (any Error).self) { try store.save([candidate]) }
        #expect(try Data(contentsOf: file) == raw && store.actions == [original] && store.writable)
    }
    @Test func externalEditIsPreservedAndStopsFurtherWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-App-Actions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ApplicationActionStore(directory: directory)
        let file = directory.appendingPathComponent("application-actions.json")
        let external = try ApplicationActionArchive(actions: [action("External")]).encoded()
        try PrivateFiles.write(external, to: file)
        #expect(throws: (any Error).self) { try store.save([action("Candidate")]) }
        let saved = try Data(contentsOf: file)
        #expect(!store.writable && store.actions.isEmpty && saved == external)
    }
    @Test func corruptAndSymbolicLinkArchivesAreNotResetOrFollowed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-App-Actions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("application-actions.json"), raw = Data("Synthetic invalid JSON".utf8)
        try PrivateFiles.write(raw, to: file)
        #expect(throws: (any Error).self) { try ApplicationActionStore(directory: directory) }
        #expect(try Data(contentsOf: file) == raw)
        try FileManager.default.removeItem(at: file)
        let other = directory.appendingPathComponent("synthetic-source.json")
        try PrivateFiles.write(raw, to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        #expect(throws: (any Error).self) { try ApplicationActionStore(directory: directory) }
        #expect(try Data(contentsOf: other) == raw)
    }
    @Test func leaseCannotBeginTwiceOrDispatchAfterRevocation() throws {
        let lease = DesktopOperationLease()
        try lease.begin(); try lease.markSubmission()
        #expect(lease.didSubmit)
        #expect(throws: (any Error).self) { try lease.begin() }
        lease.revoke()
        #expect(throws: (any Error).self) { try lease.markSubmission() }
        #expect(!lease.isCurrent && lease.didSubmit)
    }
}
