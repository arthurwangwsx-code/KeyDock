import CryptoKit
import CSQLite
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
        try await DesktopReviewScope.prepare(binding: binding, root: root, probe: { [weak self] _ in self?.process.map(DesktopReviewProcessSnapshot.init) }, beforeHash: beforeHash)
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
    @Test func missingNativeFieldIsLatchedAndASecondProbeCannotRestoreIt() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let original = try #require(f.process)
        @MainActor final class ProbeState { var snapshot: DesktopReviewProcessSnapshot; var probes = 0; init(_ value: DesktopReviewProcessSnapshot) { snapshot = value } }
        let state = ProbeState(.init(original))
        let scope = try await DesktopReviewScope.prepare(binding: f.binding, root: f.root, probe: { _ in state.probes += 1; return state.snapshot })
        state.snapshot.bundleIdentifier = nil
        #expect(!scope.isCurrent && scope.diagnostic == .targetIdentityChanged && scope.targetDiagnostic == .bundleIdentifierUnavailable)
        let failedProbeCount = state.probes
        state.snapshot = .init(original)
        #expect(!scope.isCurrent && !scope.permits(scope.targetIdentity))
        #expect(scope.targetDiagnostic == .bundleIdentifierUnavailable && state.probes == failedProbeCount)
    }
    @Test func firstInvalidationCategorySurvivesLaterChanges() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }; let scope = try await f.prepare()
        try Data("synthetic replacement".utf8).write(to: f.marker)
        #expect(!scope.isCurrent && scope.diagnostic == .markerMetadataChanged)
        f.process = nil; #expect(!scope.isCurrent && scope.diagnostic == .markerMetadataChanged)
    }
    @Test func configurationChangeHasItsOwnBoundedCategory() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }; let scope = try await f.prepare()
        try PrivateFiles.write(Data("synthetic".utf8), to: scope.dataDirectory.appendingPathComponent("configuration.json"))
        #expect(!scope.isCurrent && scope.diagnostic == .configurationIdentityChanged)
    }
    @Test func processBirthChangeHasItsOwnCategory() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }; let scope = try await f.prepare()
        let original = try #require(f.process)
        f.process = .init(pid: original.pid, launchTime: original.launchTime + 1, bundleIdentifier: original.bundleIdentifier,
                          appPath: original.appPath, executablePath: original.executablePath)
        #expect(!scope.isCurrent && scope.diagnostic == .targetIdentityChanged)
    }
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
        await #expect(throws: (any Error).self) { try await DesktopReviewScope.prepare(binding: b, root: root, probe: { _ in f.process.map(DesktopReviewProcessSnapshot.init) }) }
    }
    @Test(arguments: ["/./", "/../", "//"])
    func noncanonicalFixturePathsAreRefused(_ component: String) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let b = DesktopReviewBuildBinding(rootParent: f.binding.rootParent, reviewBundleIdentifier: f.binding.reviewBundleIdentifier,
            fixtureBundleIdentifier: f.binding.fixtureBundleIdentifier, fixtureAppPath: f.parent.path + component + f.app.lastPathComponent,
            fixtureBinarySHA256: f.binding.fixtureBinarySHA256, fixtureInfoSHA256: f.binding.fixtureInfoSHA256)
        await #expect(throws: DesktopReviewError.invalidScope) { try await DesktopReviewScope.prepare(binding: b, root: f.root, probe: { _ in f.process.map(DesktopReviewProcessSnapshot.init) }) }
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
        await #expect(throws: DesktopReviewError.invalidScope) { try await DesktopReviewScope.prepare(binding: b, root: f.root, probe: { _ in f.process.map(DesktopReviewProcessSnapshot.init) }) }
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
    @Test(arguments: ["clipboard.sqlite", "clipboard.sqlite-journal", "clipboard.sqlite-wal", "clipboard.sqlite-shm"])
    func linkedClipboardFilesAreRefusedWithoutChangingTheTarget(_ name: String) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), outside = f.parent.appendingPathComponent("protected-synthetic-clipboard")
        let bytes = Data("Synthetic protected data".utf8)
        try bytes.write(to: outside); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        let path = scope.dataDirectory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        #expect(throws: DesktopReviewError.invalidScope) { try scope.prepareClipboardStorage() }
        #expect(try Data(contentsOf: outside) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test(arguments: ["hardlink", "fifo", "mode", "orphanJournal"])
    func unsafeClipboardObjectsAndOrphanRecoveryFilesAreNotOpenedOrDeleted(_ kind: String) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), path = scope.dataDirectory.appendingPathComponent("clipboard.sqlite")
        switch kind {
        case "hardlink":
            try PrivateFiles.write(Data("Synthetic linked database".utf8), to: path)
            try FileManager.default.linkItem(at: path, to: f.parent.appendingPathComponent("linked-db"))
        case "fifo": #expect(mkfifo(path.path, 0o600) == 0)
        case "mode": try Data("Synthetic unsafe mode".utf8).write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        default: try PrivateFiles.write(Data("Synthetic recovery file".utf8), to: scope.dataDirectory.appendingPathComponent("clipboard.sqlite-journal"))
        }
        #expect(throws: DesktopReviewError.invalidScope) { try scope.prepareClipboardStorage() }
        if kind == "orphanJournal" {
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(try Data(contentsOf: scope.dataDirectory.appendingPathComponent("clipboard.sqlite-journal")) == Data("Synthetic recovery file".utf8))
        }
    }
    @Test func normalSQLiteMutationsKeepTheScopeCurrentAndForeignURLsNeverCreateDirectories() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), lifetime = try scope.prepareClipboardStorage()
        let outside = f.parent.appendingPathComponent("must-not-be-created/db.sqlite")
        #expect(throws: ClipboardDatabaseError.open) { try ClipboardStore(url: outside, storageLifetime: lifetime) }
        #expect(!FileManager.default.fileExists(atPath: outside.deletingLastPathComponent().path))
        let store = try ClipboardStore(url: lifetime.databaseURL, storageLifetime: lifetime)
        #expect(try await store.insert(text: "Synthetic mutable database", source: "Synthetic") == .stored)
        let rows = try await store.entries()
        let row = try #require(rows.first)
        try await store.setPinned(id: row.id, pinned: true)
        #expect(scope.isCurrent)
        try await store.prune(); try await store.delete(id: row.id); try await store.clear()
        let remaining = try await store.entries()
        #expect(scope.isCurrent && remaining.isEmpty)
    }
    @Test func databaseReplacementRejectsStoreAccessAndCannotReauthorizeAfterRestoration() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), lifetime = try scope.prepareClipboardStorage()
        let store = try ClipboardStore(url: lifetime.databaseURL, storageLifetime: lifetime)
        _ = try await store.insert(text: "Synthetic original database", source: "Synthetic")
        let moved = f.parent.appendingPathComponent("old.sqlite")
        try FileManager.default.moveItem(at: lifetime.databaseURL, to: moved)
        try PrivateFiles.write(Data(), to: lifetime.databaseURL)
        await #expect(throws: DesktopReviewError.unavailable) { try await store.entries() }
        try FileManager.default.removeItem(at: lifetime.databaseURL); try FileManager.default.moveItem(at: moved, to: lifetime.databaseURL)
        #expect(!scope.isCurrent)
        await #expect(throws: DesktopReviewError.unavailable) { try await store.clear() }
        await #expect(throws: DesktopReviewError.unavailable) { try await store.insert(text: "Synthetic rejected write", source: "Synthetic") }
    }
    @Test func storageLifetimeRetainsOwnershipAfterTheScopeIsReleased() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        var scope: DesktopReviewScope? = try await f.prepare()
        var lifetime: (any ClipboardStorageLifetime)? = try scope!.prepareClipboardStorage()
        scope = nil
        try lifetime?.validate()
        await #expect(throws: DesktopReviewError.alreadyOwned) { try await f.prepare() }
        lifetime = nil
        let next = try await f.prepare()
        #expect(next.isCurrent)
    }
    @Test func repeatedIdentityChecksDoNotReleaseSQLitePOSIXLocks() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), lifetime = try scope.prepareClipboardStorage()
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(lifetime.databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db); withExtendedLifetime(lifetime) {} }
        #expect(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        for _ in 0..<20 { #expect(scope.isCurrent); try lifetime.validate() }
        let database = lifetime.databaseURL.path
        let output = try await Task.detached { () throws -> String in
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import signal,sqlite3,sys\nsignal.alarm(4)\nc=sqlite3.connect(sys.argv[1],timeout=0)\ntry:\n c.execute('BEGIN IMMEDIATE'); print('acquired')\nexcept sqlite3.OperationalError as e:\n if str(e) not in ('database is locked','database table is locked'): raise\n print('busy')\nfinally:\n c.close()", database]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); pipe.fileHandleForWriting.closeFile()
            let deadline = Date().addingTimeInterval(6)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { process.terminate() }
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline { usleep(10_000) }
            guard !process.isRunning, process.terminationStatus == 0 else { throw DesktopReviewError.unavailable }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        #expect(output == "busy")
    }
    @Test(arguments: [false, true])
    func outsideConfigurationChangesArePreservedAndRevokeTheScope(_ initiallyPresent: Bool) async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), url = scope.dataDirectory.appendingPathComponent("configuration.json")
        if initiallyPresent { try scope.writeConfiguration(Data("Synthetic confirmed settings".utf8), to: url) }
        let changed = Data("Synthetic external change".utf8)
        try PrivateFiles.write(changed, to: url)
        #expect(!scope.isCurrent)
        #expect(throws: DesktopReviewError.invalidScope) { try scope.writeConfiguration(Data("Must not overwrite".utf8), to: url) }
        #expect(try Data(contentsOf: url) == changed)
    }
    @Test func confirmedConfigurationCommitsAndDatabaseGrowthKeepOneValidOwner() async throws {
        let f = try ReviewScopeFixture(); defer { f.cleanup() }
        let scope = try await f.prepare(), lifetime = try scope.prepareClipboardStorage()
        let store = try ClipboardStore(url: lifetime.databaseURL, storageLifetime: lifetime)
        let inserts = Task.detached {
            for index in 0..<30 { _ = try await store.insert(text: "Synthetic growing row \(index)", source: "Synthetic") }
        }
        for index in 0..<10 {
            try scope.writeConfiguration(Data("Synthetic confirmed revision \(index)".utf8), to: scope.dataDirectory.appendingPathComponent("configuration.json"))
            await Task.yield()
        }
        try await inserts.value
        #expect(scope.isCurrent)
        let rows = try await store.entries()
        #expect(rows.count == 30)
    }
}
