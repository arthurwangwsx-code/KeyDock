import Foundation
import Testing
import CommandCore
@testable import MacAdapters

@Suite(.serialized) @MainActor struct DesktopWorkspaceStoreTests {
    private func value(_ name: String) throws -> SavedDesktopWorkspace {
        try .init(name: name, entries: [.init(applicationID: "app./Applications/Synthetic.app")])
    }
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-DesktopWorkspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    @Test func namespacesAndAnOldConfigurationRewriteCannotDiscardOtherArchives() throws {
        try withDirectory { directory in
            let actions = try ApplicationActionStore(directory: directory), workspaces = try DesktopWorkspaceStore(directory: directory)
            let action = try SavedApplicationAction(name: "Synthetic action", applicationID: "app./Applications/Synthetic.app", behavior: .show), workspace = try value("Synthetic workspace")
            try actions.save([action]); try workspaces.save([workspace])
            try PrivateFiles.write(Data("{}".utf8), to: directory.appendingPathComponent("configuration.json"))
            #expect(try ApplicationActionStore(directory: directory).actions == [action])
            #expect(try DesktopWorkspaceStore(directory: directory).workspaces == [workspace])
            try workspaces.save([])
            #expect(try ApplicationActionStore(directory: directory).actions == [action])
        }
    }
    @Test(arguments: [false,true]) func recoveryMarkersQuarantineOnlyTheirOwnNamespace(workspaceMarker: Bool) throws {
        try withDirectory { directory in
            let action = try SavedApplicationAction(name: "Synthetic", applicationID: "app./Applications/Synthetic.app", behavior: .show), workspace = try value("Synthetic")
            try ApplicationActionStore(directory: directory).save([action]); try DesktopWorkspaceStore(directory: directory).save([workspace])
            let prefix = workspaceMarker ? ".desktop-workspaces-transaction-" : ".application-actions-transaction-"
            let marker = directory.appendingPathComponent(prefix+UUID().uuidString)
            try Data("Synthetic unknown recovery contents".utf8).write(to: marker)
            let actions = try ApplicationActionStore(directory: directory), workspaces = try DesktopWorkspaceStore(directory: directory)
            #expect(actions.writable == workspaceMarker && workspaces.writable == !workspaceMarker)
            #expect(actions.actions == (workspaceMarker ? [action] : []))
            #expect(workspaces.workspaces == (workspaceMarker ? [] : [workspace]))
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }
    @Test(arguments: [false,true], [ArchiveStoreFaultStage.beforeCandidateWrite,.afterCandidateFileSync,.beforeCommit,.afterCommit,.afterCommitDirectorySync])
    func writeFailuresRestoreExactBytesOrTheAbsentState(hasFile: Bool, stage: ArchiveStoreFaultStage) throws {
        try withDirectory { directory in
            let original = try value("Original"), file = directory.appendingPathComponent("desktop-workspaces.json")
            var bytes = try DesktopWorkspaceArchive(workspaces: [original]).encoded(); bytes.append(10)
            if hasFile { try PrivateFiles.write(bytes, to: file) }
            let store = try DesktopWorkspaceStore(directory: directory, faultHook: { if $0 == stage { throw CocoaError(.fileWriteUnknown) } })
            #expect(throws: (any Error).self) { try store.save([value("Candidate")]) }
            #expect(store.writable && store.workspaces == (hasFile ? [original] : []))
            #expect((try? Data(contentsOf: file)) == (hasFile ? bytes : nil))
        }
    }
    @Test func corruptUnknownAndExternalArchivesArePreserved() throws {
        try withDirectory { directory in
            let store = try DesktopWorkspaceStore(directory: directory), file = directory.appendingPathComponent("desktop-workspaces.json")
            let bytes = Data("{\"schemaVersion\":2,\"workspaces\":[]}".utf8)
            try PrivateFiles.write(bytes, to: file)
            #expect(throws: (any Error).self) { try store.save([value("Candidate")]) }
            #expect(!store.writable)
            #expect(throws: (any Error).self) { try DesktopWorkspaceStore(directory: directory) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
