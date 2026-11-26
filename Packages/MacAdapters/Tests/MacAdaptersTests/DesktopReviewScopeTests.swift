import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MacAdapters

@MainActor private final class ReviewScopeFixture {
    let parent: URL
    let root: URL
    let app: URL
    let binary: URL
    let info: URL
    let marker: URL
    let binding: DesktopReviewBuildBinding
    var process: DesktopReviewProcessIdentity?
    init() throws {
        parent = try PrivateFiles.physicalTemporaryDirectory().appendingPathComponent("KeyDock-ScopeTest-" + UUID().uuidString)
        root = parent.appendingPathComponent("KeyDock-DesktopReview-" + UUID().uuidString)
        app = parent.appendingPathComponent("SyntheticFixture.app")
        binary = app.appendingPathComponent("Contents/MacOS/" + DesktopReviewScope.fixtureExecutableName)
        info = app.appendingPathComponent("Contents/Info.plist")
        marker = root.appendingPathComponent("review-session.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let body = Data("synthetic file identity only; no executable is launched".utf8)
        try body.write(to: binary); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": DesktopReviewScope.fixtureBundleIdentifier,
            "CFBundleExecutable": DesktopReviewScope.fixtureExecutableName], format: .xml, options: 0)
        try plist.write(to: info)
        binding = .init(rootParent: parent.path, reviewBundleIdentifier: DesktopReviewScope.bundleIdentifier,
            fixtureBundleIdentifier: DesktopReviewScope.fixtureBundleIdentifier, fixtureAppPath: app.path,
            fixtureBinarySHA256: Self.hash(body), fixtureInfoSHA256: Self.hash(plist))
        let value = DesktopReviewMarker(schemaVersion: 1, rootID: UUID(uuidString: String(root.lastPathComponent.dropFirst("KeyDock-DesktopReview-".count)))!,
            reviewBundleIdentifier: DesktopReviewScope.bundleIdentifier, fixturePID: 42424, fixtureLaunchTime: 1234.5)
        try JSONEncoder().encode(value).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        process = .init(pid: value.fixturePID, launchTime: value.fixtureLaunchTime, bundleIdentifier: DesktopReviewScope.fixtureBundleIdentifier,
                        appPath: app.path, executablePath: binary.path)
    }
    func prepare(beforeHash: @escaping @Sendable () -> Void = {}) async throws -> DesktopReviewScope {
        try await DesktopReviewScope.prepare(binding: binding, root: root, probe: { [weak self] _ in self?.process }, beforeHash: beforeHash)
    }
    func cleanup() { try? FileManager.default.removeItem(at: parent) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class ReviewHashGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    private var mainThread = false
    private var expired = false
    func wait() {
        lock.lock(); entered = true; mainThread = Thread.isMainThread; lock.unlock()
        let result = release.wait(timeout: .now() + 10)
        lock.lock(); expired = result == .timedOut; lock.unlock()
    }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var wasMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

@Suite(.serialized) @MainActor struct DesktopReviewScopeTests {
    @Test func validScopeAllowsDirectoryGrowthAndOnlyTheBoundInstance() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare()
        #expect(scope.isCurrent && scope.permits(scope.targetIdentity))
        #expect(!scope.permits(.init(pid: 31313, launchDate: Date(timeIntervalSince1970: 1234.5), name: "Synthetic other")))
        #expect(scope.isCurrent)
        try FileManager.default.createDirectory(at: scope.dataDirectory.appendingPathComponent("ordinary-child"), withIntermediateDirectories: false)
        #expect(scope.isCurrent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scope.sessionDirectory.path).isEmpty)
    }
    @Test(arguments: ["symlink", "fifo", "hardlink", "mode", "oversize", "schema"])
    func invalidMarkersFailBeforeCreatingData(_ kind: String) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let protected = f.parent.appendingPathComponent("protected-synthetic-file")
        try Data("preserve".utf8).write(to: protected)
        switch kind {
        case "symlink": try FileManager.default.removeItem(at: f.marker); try FileManager.default.createSymbolicLink(at: f.marker, withDestinationURL: protected)
        case "fifo": try FileManager.default.removeItem(at: f.marker); #expect(mkfifo(f.marker.path, 0o600) == 0)
        case "hardlink": try FileManager.default.linkItem(at: f.marker, to: f.parent.appendingPathComponent("linked-marker"))
        case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.marker.path)
        case "oversize": try Data(repeating: 65, count: 4097).write(to: f.marker)
        default: try Data("{}".utf8).write(to: f.marker)
        }
        await #expect(throws: (any Error).self) { try await f.prepare() }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Data").path))
        #expect(try Data(contentsOf: protected) == Data("preserve".utf8))
    }
    @Test func symlinkAncestorIsRefused() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let alias = f.parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.parent)
        let root = alias.appendingPathComponent(f.root.lastPathComponent)
        let b = DesktopReviewBuildBinding(rootParent: alias.path, reviewBundleIdentifier: f.binding.reviewBundleIdentifier,
            fixtureBundleIdentifier: f.binding.fixtureBundleIdentifier, fixtureAppPath: f.app.path,
            fixtureBinarySHA256: f.binding.fixtureBinarySHA256, fixtureInfoSHA256: f.binding.fixtureInfoSHA256)
        await #expect(throws: (any Error).self) { try await DesktopReviewScope.prepare(binding: b, root: root, probe: { _ in f.process }) }
    }
    @Test(arguments: ["/./", "/../", "//"])
    func noncanonicalFixturePathsAreRefused(_ component: String) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let b = DesktopReviewBuildBinding(rootParent: f.binding.rootParent, reviewBundleIdentifier: f.binding.reviewBundleIdentifier,
            fixtureBundleIdentifier: f.binding.fixtureBundleIdentifier, fixtureAppPath: f.parent.path + component + f.app.lastPathComponent,
            fixtureBinarySHA256: f.binding.fixtureBinarySHA256, fixtureInfoSHA256: f.binding.fixtureInfoSHA256)
        await #expect(throws: DesktopReviewError.invalidScope) { try await DesktopReviewScope.prepare(binding: b, root: f.root, probe: { _ in f.process }) }
    }
    @Test(arguments: ["marker", "binary", "info"])
    func sameBytesAtANewInodePermanentlyRevoke(_ kind: String) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare()
        let path = kind == "marker" ? f.marker : (kind == "binary" ? f.binary : f.info)
        let old = path.deletingLastPathComponent().appendingPathComponent("old-" + path.lastPathComponent)
        let bytes = try Data(contentsOf: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        try FileManager.default.moveItem(at: path, to: old)
        try bytes.write(to: path); try FileManager.default.setAttributes([.posixPermissions: attributes[.posixPermissions]!], ofItemAtPath: path.path)
        #expect(!scope.isCurrent)
        try FileManager.default.removeItem(at: path); try FileManager.default.moveItem(at: old, to: path)
        #expect(!scope.isCurrent && !scope.permits(scope.targetIdentity))
    }
    @Test func replacementRootAndRestoredOldRootCannotReauthorize() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), moved = f.parent.appendingPathComponent("moved-root")
        try FileManager.default.moveItem(at: f.root, to: moved)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(!scope.isCurrent)
        try FileManager.default.removeItem(at: f.root); try FileManager.default.moveItem(at: moved, to: f.root)
        #expect(!scope.isCurrent)
    }
    @Test func processBirthChangesPermanentlyRevoke() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), original = f.process!
        f.process = .init(pid: original.pid, launchTime: original.launchTime + 1, bundleIdentifier: original.bundleIdentifier,
                          appPath: original.appPath, executablePath: original.executablePath)
        #expect(!scope.isCurrent)
        f.process = original
        #expect(!scope.isCurrent)
    }
    @Test(arguments: ["birth", "bundle", "path", "executable", "missing"])
    func mismatchedProcessIsUnavailableRatherThanAlreadyOwned(_ kind: String) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let p = f.process!
        f.process = kind == "missing" ? nil : .init(pid: p.pid,
            launchTime: p.launchTime + (kind == "birth" ? 1 : 0),
            bundleIdentifier: p.bundleIdentifier + (kind == "bundle" ? ".different" : ""),
            appPath: p.appPath + (kind == "path" ? "-different" : ""),
            executablePath: p.executablePath + (kind == "executable" ? "-different" : ""))
        await #expect(throws: DesktopReviewError.unavailable) { try await f.prepare() }
    }
    @Test func configurationWritesStayInOwnedDataAndRejectLinkedDestinations() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), destination = scope.dataDirectory.appendingPathComponent("configuration.json")
        try scope.writeConfiguration(Data("synthetic-settings".utf8), to: destination)
        #expect(try Data(contentsOf: destination) == Data("synthetic-settings".utf8))
        #expect(scope.isCurrent)
        let outside = f.parent.appendingPathComponent("protected-settings")
        try Data("preserve".utf8).write(to: outside)
        #expect(throws: (any Error).self) { try scope.writeConfiguration(Data(), to: outside) }
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try scope.writeConfiguration(Data(), to: destination) }
        #expect(try Data(contentsOf: outside) == Data("preserve".utf8))
    }
    @Test func restartingLoadsSettingsButCreatesAnEmptyAuxiliarySession() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let settings = Data("{}".utf8)
        @MainActor func firstLaunch() async throws -> URL {
            let scope = try await f.prepare()
            try scope.writeConfiguration(settings, to: scope.dataDirectory.appendingPathComponent("configuration.json"))
            try Data("synthetic old auxiliary data".utf8).write(to: scope.sessionDirectory.appendingPathComponent("old-record"))
            return scope.sessionDirectory
        }
        let old = try await firstLaunch()
        let scope = try await f.prepare()
        #expect(scope.initialConfigurationData == settings)
        #expect(scope.sessionDirectory != old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scope.sessionDirectory.path).isEmpty)
    }
    @Test func hashFailureReleasesTheDirectoryOwner() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let b = DesktopReviewBuildBinding(rootParent: f.binding.rootParent, reviewBundleIdentifier: f.binding.reviewBundleIdentifier,
            fixtureBundleIdentifier: f.binding.fixtureBundleIdentifier, fixtureAppPath: f.binding.fixtureAppPath,
            fixtureBinarySHA256: String(repeating: "0", count: 64), fixtureInfoSHA256: f.binding.fixtureInfoSHA256)
        await #expect(throws: DesktopReviewError.invalidScope) { try await DesktopReviewScope.prepare(binding: b, root: f.root, probe: { _ in f.process }) }
        let scope = try await f.prepare()
        #expect(scope.isCurrent)
    }
    @Test func cancellationWaitsForWorkerBeforeReleasingDirectoryOwner() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let gate = ReviewHashGate()
        defer { gate.release.signal() }
        let preparation = Task { try await f.prepare(beforeHash: { gate.wait() }) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard gate.started else {
            preparation.cancel(); gate.release.signal()
            _ = try? await preparation.value
            Issue.record("Preparation did not reach the controlled hash boundary")
            return
        }
        #expect(!gate.wasMainThread)
        preparation.cancel()
        await #expect(throws: DesktopReviewError.alreadyOwned) { try await f.prepare() }
        gate.release.signal()
        await #expect(throws: (any Error).self) { try await preparation.value }
        #expect(!gate.timedOut)
        let scope = try await f.prepare()
        #expect(scope.isCurrent)
    }
}
