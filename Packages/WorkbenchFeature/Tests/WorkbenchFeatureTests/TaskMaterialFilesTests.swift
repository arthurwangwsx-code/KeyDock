import Foundation
import Darwin
import Testing
@testable import WorkbenchFeature

private final class MaterialReadCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [TaskMaterialReadKind: Int] = [:]
    func record(_ kind: TaskMaterialReadKind, _ count: Int) { lock.withLock { counts[kind, default: 0] += count } }
    func count(_ kind: TaskMaterialReadKind) -> Int { lock.withLock { counts[kind, default: 0] } }
}

struct TaskMaterialFilesTests {
    private func folder() throws -> URL {
        try TaskMaterialTestFixtures.directory("Files")
    }
    private func key() -> TaskMaterialKey { .init(receiptStore: .ai, invocationID: UUID(), receiptRecordIdentity: UUID()) }
    private func frame(_ key: TaskMaterialKey, _ input: String = "synthetic", output: String? = nil, revision: UInt64 = 1) throws -> Data {
        try TaskMaterialFormat.frame(.init(input: input, visibleResult: output, resultKind: output == nil ? nil : .visibleResult,
            resultWasPartial: output == nil ? nil : false, resultCapturedAt: output == nil ? nil : 9),
            key: key, version: .init(identity: UUID(), revision: revision), createdAt: 10, expiresAt: 20).0
    }

    @Test func headerOnlyReadNeverReadsPayloadUntilExplicitRead() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let counts = MaterialReadCounts(), id = key()
        let files = try TaskMaterialFiles(directory: directory, create: false, observeRead: counts.record)
        let bytes = try frame(id, output: String(repeating: "synthetic", count: 50_000))
        try files.writeBody(bytes, key: id, expected: nil, validate: {}, commit: { try $0() })
        let handle = try #require(try files.readHeader(id))
        #expect(counts.count(.payload) == 0)
        #expect(counts.count(.header) > 12 && counts.count(.header) < TaskMaterialLimits.headerBytes + 12)
        #expect(handle.fileIdentity.size == bytes.count)
        let body = try files.readBody(handle)
        #expect(body.input == "synthetic" && body.visibleResult?.utf8.count == 450_000)
        #expect(counts.count(.payload) == handle.header.payloadBytes)
    }

    @Test func descriptorOwnerLeaseRejectsSecondWriterAndReleasesAtEndOfLifetime() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var first: TaskMaterialFiles? = try .init(directory: directory, create: false)
        #expect(try first?.names().contains(TaskMaterialFiles.lockName) == true)
        #expect(throws: TaskMaterialError.busy) { try TaskMaterialFiles(directory: directory, create: false) }
        first = nil
        let next = try TaskMaterialFiles(directory: directory, create: false)
        #expect(try next.names() == [TaskMaterialFiles.lockName])
    }

    @Test func rebindingDirectoryCannotRedirectOldDescriptorOrAcknowledgeWrite() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("materials"), retained = root.appendingPathComponent("retained")
        let files = try TaskMaterialFiles(directory: directory, create: true)
        try FileManager.default.moveItem(at: directory, to: retained)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let id = key()
        #expect(throws: TaskMaterialError.changed) {
            try files.writeBody(frame(id), key: id, expected: nil, validate: {}, commit: { try $0() })
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: retained.appendingPathComponent(id.fileName).path))
    }

    @Test func linksFIFOAndChangedFilesAreRefusedWithoutFollowingThem() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let files = try TaskMaterialFiles(directory: directory, create: false), id = key()
        let target = directory.appendingPathComponent("synthetic-target"), destination = directory.appendingPathComponent(id.fileName)
        try Data("unchanged".utf8).write(to: target); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        #expect(throws: TaskMaterialError.unsafeEntry) { try files.readHeader(id) }
        try FileManager.default.removeItem(at: destination)
        #expect(link(target.path, destination.path) == 0)
        #expect(throws: TaskMaterialError.unsafeEntry) { try files.readHeader(id) }
        try FileManager.default.removeItem(at: destination)
        #expect(mkfifo(destination.path, mode_t(0o600)) == 0)
        #expect(throws: TaskMaterialError.unsafeEntry) { try files.readHeader(id) }
        try FileManager.default.removeItem(at: destination)
        try files.writeBody(frame(id), key: id, expected: nil, validate: {}, commit: { try $0() })
        let old = try #require(try files.readHeader(id))
        try files.writeBody(frame(id, "changed", revision: 2), key: id, expected: old.fileIdentity, validate: {}, commit: { try $0() })
        #expect(throws: TaskMaterialError.changed) { try files.readBody(old) }
        #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
    }

    @Test func failedBeforeRenamePreservesOldBytesAndAfterRenameReportsUncertainty() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let id = key()
        let original = try frame(id)
        do {
            let files = try TaskMaterialFiles(directory: directory, create: false)
            try files.writeBody(original, key: id, expected: nil, validate: {}, commit: { try $0() })
        }
        let updated = try frame(id, "updated", revision: 2)
        do {
            let files = try TaskMaterialFiles(directory: directory, create: false, fault: { _, point, _ in point == .beforeRename ? EIO : nil })
            let old = try #require(try files.readHeader(id))
            #expect(throws: TaskMaterialError.io(EIO)) { try files.writeBody(updated, key: id, expected: old.fileIdentity, validate: {}, commit: { try $0() }) }
            #expect(try Data(contentsOf: directory.appendingPathComponent(id.fileName)) == original)
        }
        let files = try TaskMaterialFiles(directory: directory, create: false, fault: { _, point, _ in point == .afterRename ? EIO : nil })
        let old = try #require(try files.readHeader(id))
        #expect(throws: TaskMaterialError.durabilityUncertain(EIO)) { try files.writeBody(updated, key: id, expected: old.fileIdentity, validate: {}, commit: { try $0() }) }
        #expect(try Data(contentsOf: directory.appendingPathComponent(id.fileName)) == updated)
    }

    @Test func revokedPermissionAtCommitHookCannotPublishBody() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let fence = TaskMaterialFence(), permit = fence.setEnabled(true), id = key()
        let files = try TaskMaterialFiles(directory: directory, create: false, fault: { _, point, _ in
            if point == .beforeRename { fence.setEnabled(false) }; return nil
        })
        #expect(throws: TaskMaterialError.permissionDenied) {
            try files.writeBody(frame(id), key: id, expected: nil, validate: {}, commit: { try fence.commit(if: permit, $0) })
        }
        #expect(try files.readHeader(id) == nil)
        #expect(try files.names() == [TaskMaterialFiles.lockName])
    }

    @Test func replacingOwnerLockInvalidatesTheOldOwnerAndLockCannotBeRemovedThroughAPI() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let files = try TaskMaterialFiles(directory: directory, create: false)
        let lock = try #require(try files.identity(TaskMaterialFiles.lockName))
        #expect(throws: TaskMaterialError.unsafeEntry) { try files.remove(TaskMaterialFiles.lockName, expected: lock) }
        try FileManager.default.moveItem(at: directory.appendingPathComponent(TaskMaterialFiles.lockName), to: directory.appendingPathComponent("retained-lock"))
        let replacement = try TaskMaterialFiles(directory: directory, create: false)
        #expect(try replacement.names().contains("retained-lock"))
        #expect(throws: TaskMaterialError.changed) { try files.requireBoundDirectory() }
    }

    @Test func changedTemporaryNameCannotPublishOrDeleteTheReplacement() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let id = key()
        let files = try TaskMaterialFiles(directory: directory, create: false, fault: { role, point, _ in
            if role == .body, point == .beforeRename {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                if let temporary = names.first(where: { $0.hasPrefix(".material-v1-") }) {
                    let location = directory.appendingPathComponent(temporary)
                    try? FileManager.default.moveItem(at: location, to: directory.appendingPathComponent("retained-original"))
                    try? Data("foreign replacement".utf8).write(to: location)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
                }
            }
            return nil
        })
        #expect(throws: TaskMaterialError.changed) { try files.writeBody(frame(id), key: id, expected: nil, validate: {}, commit: { try $0() }) }
        #expect(try files.readHeader(id) == nil)
        let temporary = try #require(try files.names().first(where: { $0.hasPrefix(".material-v1-") }))
        #expect(try Data(contentsOf: directory.appendingPathComponent(temporary)) == Data("foreign replacement".utf8))
    }

    @Test func commitThatDoesNotPerformRenameCannotReturnSuccess() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let files = try TaskMaterialFiles(directory: directory, create: false), id = key()
        #expect(throws: TaskMaterialError.io(EIO)) { try files.writeBody(frame(id), key: id, expected: nil, validate: {}, commit: { _ in }) }
        #expect(try files.readHeader(id) == nil)
    }

    @Test func deleteRejectsAReplacementMadeAfterTheInitialIdentityCheck() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let id = key(), replacement = try frame(id, "new material birth")
        let files = try TaskMaterialFiles(directory: directory, create: false, fault: { _, point, name in
            if point == .beforeDelete {
                let location = directory.appendingPathComponent(name)
                try? FileManager.default.moveItem(at: location, to: directory.appendingPathComponent("retained-before-delete"))
                try? replacement.write(to: location)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
            }
            return nil
        })
        try files.writeBody(frame(id), key: id, expected: nil, validate: {}, commit: { try $0() })
        let old = try #require(try files.readHeader(id))
        #expect(throws: TaskMaterialError.changed) { try files.remove(id.fileName, expected: old.fileIdentity) }
        #expect(try Data(contentsOf: directory.appendingPathComponent(id.fileName)) == replacement)
    }
}
