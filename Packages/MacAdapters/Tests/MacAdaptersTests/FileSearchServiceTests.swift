import Foundation
import Testing
@testable import MacAdapters

private struct FileSearchFixture {
    let parent: URL
    let root: URL
    let outside: URL
    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-file-search-proposal-" + UUID().uuidString)
        root = parent.appendingPathComponent("selected")
        outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }
    func file(_ relative: String, body: String = "Synthetic body", in base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: parent) }
}
private final class FileSearchReturnGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var cancelled = false
    func wait(_ query: String) {
        guard query == "first" else { return }
        condition.lock(); entered = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(3)
        while !released {
            if !condition.wait(until: deadline) { break }
        }
        cancelled = Task.isCancelled
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hasEntered() -> Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func wasCancelled() -> Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
}
@Suite(.serialized) struct FileSearchServiceTests {
    private func entered(_ gate: FileSearchReturnGate) async throws {
        for _ in 0..<200 {
            if gate.hasEntered() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FileSearchError.invalidQuery
    }
    @Test func systemAliasAndPhysicalRootsWorkButFinalDirectorySymlinkIsRejected() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("identity.txt")
        let service = try FileSearchService()
        let logical = try await service.search(query:"identity",roots:[fixture.root])
        let physical = try #require(logical.scopes.first?.resolvedURL)
        #expect(logical.scopes.first?.status == .available && logical.results.count == 1)
        #expect(try await service.search(query:"identity",roots:[physical]).results.count == 1)
        let link = fixture.parent.appendingPathComponent("final-link",isDirectory:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:fixture.root)
        let rejected = try await service.search(query:"identity",roots:[link])
        #expect(rejected.results.isEmpty && rejected.scopes.first?.status == .symbolicLinkExcluded)
    }
    @Test func nameSearchDoesNotIndexBodiesAndUsesExplicitScopes() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("Résumé-synthetic.txt", body: "synthetic-body-only-token")
        _ = try fixture.file("Résumé-outside.txt", in: fixture.outside)
        let service = try FileSearchService()
        let report = try await service.search(query: "resume", roots: [fixture.root])
        #expect(report.results.map(\.title) == ["Résumé-synthetic.txt"])
        #expect(report.scopes.count == 1 && report.scopes[0].status == .available && !report.searchesFileContents)
        let result = try #require(report.results.first)
        #expect(try await service.validate(result) == result.url)
        let content = try await service.search(query: "body-only-token", roots: [fixture.root])
        #expect(content.results.isEmpty)
        await #expect(throws: FileSearchError.staleResult) { try await service.validate(result) }
    }
    @Test func hiddenPackagesAndSymlinkTargetsAreExcluded() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("needle-visible.txt")
        _ = try fixture.file(".hidden/needle-hidden.txt")
        _ = try fixture.file("Synthetic.app/Contents/needle-package.txt")
        let outsideFile = try fixture.file("needle-outside.txt", in: fixture.outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked-directory"), withDestinationURL: fixture.outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("needle-linked.txt"), withDestinationURL: outsideFile)
        let service = try FileSearchService()
        let report = try await service.search(query: "needle", roots: [fixture.root])
        #expect(report.results.map(\.title) == ["needle-visible.txt"])
        #expect(report.skipsHiddenItems && report.skipsPackages && report.skipsSymbolicLinks)
    }
    @Test func unreadableBodyDoesNotPreventMetadataSearch() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        let file = try fixture.file("metadata-only.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let service = try FileSearchService()
        let result = try #require(try await service.search(query: "metadata-only", roots: [fixture.root]).results.first)
        #expect(try await service.validate(result) == result.url)
    }
    @Test func resultScanAndDepthBoundsAreReported() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        for index in 0..<5 { _ = try fixture.file("hit-\(index).txt") }
        let service = try FileSearchService()
        let limited = try await service.search(query: "hit-", roots: [fixture.root], limit: 2)
        #expect(limited.results.count == 2 && limited.truncationReasons.contains(.resultLimit))
        let small = try FileSearchService(limits: .init(maxScannedItems: 2))
        let scanned = try await small.search(query: "not-present", roots: [fixture.root])
        #expect(scanned.scannedItems == 2 && scanned.truncationReasons.contains(.scannedItemLimit))
        _ = try fixture.file("nested/hit-deep.txt")
        let shallow = try FileSearchService(limits: .init(maxDepth: 0))
        let depth = try await shallow.search(query: "hit-deep", roots: [fixture.root])
        #expect(depth.results.isEmpty && depth.truncationReasons.contains(.depthLimit))
    }
    @Test func targetRevisionAndReplacementAreRecheckedBeforeReveal() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        let file = try fixture.file("needle.txt", body: "short")
        let service = try FileSearchService()
        let first = try #require(try await service.search(query: "needle", roots: [fixture.root]).results.first)
        try Data("Synthetic replacement with a different byte count".utf8).write(to: file)
        await #expect(throws: FileSearchError.targetChanged) { try await service.validate(first) }
        let second = try #require(try await service.search(query: "needle", roots: [fixture.root]).results.first)
        #expect(first.objectRevision != second.objectRevision)
        try FileManager.default.removeItem(at: file)
        let outside = try fixture.file("needle.txt", in: fixture.outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        await #expect(throws: FileSearchError.notRegularFile) { try await service.validate(second) }
    }
    @Test func parentDirectorySymlinkSwapAndRootReplacementInvalidateSnapshot() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("folder/needle.txt")
        _ = try fixture.file("needle.txt", in: fixture.outside)
        let service = try FileSearchService()
        let result = try #require(try await service.search(query: "needle", roots: [fixture.root]).results.first)
        let folder = fixture.root.appendingPathComponent("folder")
        try FileManager.default.moveItem(at: folder, to: fixture.root.appendingPathComponent("moved-folder"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: fixture.outside)
        await #expect(throws: FileSearchError.pathChanged) { try await service.validate(result) }
        let current = try #require(try await service.search(query: "needle", roots: [fixture.root]).results.first)
        #expect(current.url.path.contains("moved-folder"))
        try FileManager.default.moveItem(at: fixture.root, to: fixture.parent.appendingPathComponent("old-selected"))
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        _ = try fixture.file("needle.txt")
        await #expect(throws: FileSearchError.scopeChanged) { try await service.validate(current) }
    }
    @Test func lateCancelledWorkerCannotOverwriteNewQueryCache() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("first.txt"); _ = try fixture.file("second.txt")
        let gate = FileSearchReturnGate()
        let service = try FileSearchService(beforeWorkerReturns: { gate.wait($0) })
        let first = Task { try await service.search(query: "first", roots: [fixture.root]) }
        defer { first.cancel(); gate.release() }
        try await entered(gate)
        let second = try await service.search(query: "second", roots: [fixture.root])
        gate.release()
        if case .success = await first.result { Issue.record("Late old query unexpectedly published") }
        #expect(gate.wasCancelled())
        #expect(await service.currentReport()?.requestID == second.requestID)
        #expect(await service.currentReport()?.results.map(\.title) == ["second.txt"])
        let currentResult = try #require(second.results.first)
        #expect(try await service.validate(currentResult) == currentResult.url)
    }
    @Test func callerCancellationPropagatesToDetachedWorker() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("first.txt")
        let gate = FileSearchReturnGate()
        let service = try FileSearchService(beforeWorkerReturns: { gate.wait($0) })
        let task = Task { try await service.search(query: "first", roots: [fixture.root]) }
        defer { task.cancel(); gate.release() }
        try await entered(gate); task.cancel(); gate.release()
        if case .success = await task.result { Issue.record("Cancelled query unexpectedly returned results") }
        #expect(gate.wasCancelled())
        #expect(await service.currentReport() == nil)
    }
    @Test func invalidNewQueryClearsPriorAuthorityAndNeverScansOtherRoots() async throws {
        let fixture = try FileSearchFixture(); defer { fixture.cleanup() }
        _ = try fixture.file("needle.txt")
        let service = try FileSearchService()
        let result = try #require(try await service.search(query: "needle", roots: [fixture.root]).results.first)
        await #expect(throws: FileSearchError.invalidRoots) { try await service.search(query: "needle", roots: Array(repeating: fixture.root, count: 9)) }
        #expect(await service.currentReport() == nil)
        await #expect(throws: FileSearchError.staleResult) { try await service.validate(result) }
        await #expect(throws: FileSearchError.invalidLimit) { try await service.search(query: "needle", roots: [fixture.root], limit: 101) }
        let empty = try await service.search(query: " ", roots: [fixture.root])
        #expect(empty.scannedItems == 0 && empty.results.isEmpty && empty.scopes.first?.status == .notScanned)
    }
}
