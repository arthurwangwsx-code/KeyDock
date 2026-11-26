import Foundation
import Darwin
import Testing
import CommandCore
@testable import MacAdapters

@Suite(.serialized) @MainActor struct LegacyApplicationActionSnapshotTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-LegacyProof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func archive() throws -> Data {
        try ApplicationActionArchive(actions: [.init(name: "Synthetic hide", applicationID: "app./Synthetic.app", behavior: .hide)]).encoded()
    }
    @Test func absentSourceIsConfirmedEmptyAndReaderNeverCreatesDirectoriesOrFiles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Missing")
        #expect(throws: (any Error).self) { try LegacyApplicationActionSnapshot(directory: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let source = try LegacyApplicationActionSnapshot(directory: root)
        #expect(source.actions == [])
        try source.validateCurrent(); try source.validateCurrent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func validSourceIsReadOnlyAndLaterReplacementPermanentlyInvalidatesIt() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("application-actions.json"), bytes = try archive()
        try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let source = try LegacyApplicationActionSnapshot(directory: root)
        #expect(source.actions?.count == 1); try source.validateCurrent()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o644)
        try bytes.write(to: file, options: .atomic)
        #expect(throws: (any Error).self) { try source.validateCurrent() }
        #expect(source.actions == nil)
        #expect(throws: (any Error).self) { try source.validateCurrent() }
        #expect(try Data(contentsOf: file) == bytes)
    }
    @Test(arguments: ["malformed", "oversize", "symlink", "hardlink", "fifo", "writable", "recovery"])
    func unconfirmedSourcesAreRejectedWithoutCleanup(_ kind: String) throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("application-actions.json")
        try archive().write(to: file)
        switch kind {
        case "malformed": try Data("unconfirmed".utf8).write(to: file)
        case "oversize": try Data(repeating: 32, count: ApplicationActionArchive.maximumBytes + 1).write(to: file)
        case "symlink", "hardlink":
            let other = root.appendingPathComponent("retained.json")
            if kind == "symlink" {
                try FileManager.default.moveItem(at: file, to: other)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            } else { try FileManager.default.linkItem(at: file, to: other) }
        case "fifo": try FileManager.default.removeItem(at: file); #expect(mkfifo(file.path, 0o600) == 0)
        case "writable": try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        default: try Data("recovery".utf8).write(to: root.appendingPathComponent(".application-actions-transaction-synthetic"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(throws: (any Error).self) { try LegacyApplicationActionSnapshot(directory: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == names)
    }
    @Test func recoveryAppearingAfterRepeatedChecksAndRootRebindingInvalidate() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try LegacyApplicationActionSnapshot(directory: root)
        for _ in 0..<3 { try source.validateCurrent() }
        let marker = root.appendingPathComponent(".application-actions-transaction-late")
        try Data().write(to: marker)
        #expect(throws: (any Error).self) { try source.validateCurrent() }
        try FileManager.default.removeItem(at: marker)
        #expect(throws: (any Error).self) { try source.validateCurrent() }
        let second = try LegacyApplicationActionSnapshot(directory: root)
        let moved = root.appendingPathExtension("retained")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        #expect(throws: (any Error).self) { try second.validateCurrent() }
    }
}
