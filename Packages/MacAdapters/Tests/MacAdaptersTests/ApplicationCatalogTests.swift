import Foundation
import Testing
import AppKit
@testable import MacAdapters

private enum ApplicationFixtureError: Error { case deadline, missingCall }

private func makeSyntheticApplication(_ name: String, in root: URL, identifier: String = "keydock.synthetic.app") throws -> URL {
    let url = root.appendingPathComponent(name + ".app", isDirectory: true)
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "synthetic", "CFBundleIdentifier": identifier, "CFBundleDisplayName": "Synthetic App"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let executable = contents.appendingPathComponent("MacOS/synthetic")
    try Data("synthetic fixture; never executed".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return url
}

@Suite(.serialized) @MainActor struct ApplicationScannerTests {
    @Test func scansNestedAppsDeduplicatesAliasesAndPreservesSeparateCopies() async throws {
        try await withRoot { root in
            let nested = root.appendingPathComponent("Vendor")
            let first = try makeSyntheticApplication("First", in: nested)
            _ = try makeSyntheticApplication("Second", in: root)
            _ = try makeSyntheticApplication("HiddenHelper", in: first.appendingPathComponent("Contents/Helpers"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Invalid.app"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: first)
            let records = try await FileSystemApplicationScanner(roots: [root, nested, root]).scan()
            #expect(records.count == 2 && Set(records.map { $0.item.payload }).count == 2)
            #expect(Set(records.map { $0.item.title }) == ["Synthetic App"])
            #expect(records.allSatisfy { $0.item.payload == $0.item.subtitle && $0.matchesCurrentItem() })
            #expect(records.allSatisfy { !$0.item.payload.contains("HiddenHelper") && !$0.item.payload.contains("Alias.app") })
        }
    }

    @Test func missingMovedAndRemovedTargetsCannotRemainValid() async throws {
        try await withRoot { root in
            let missing = root.appendingPathComponent("Applications")
            let scanner = FileSystemApplicationScanner(roots: [missing])
            #expect(try await scanner.scan().isEmpty)
            let app = try makeSyntheticApplication("Original", in: missing)
            let before = try #require(await scanner.scan().first)
            try FileManager.default.moveItem(at: app, to: missing.appendingPathComponent("Moved.app"))
            #expect(!before.matchesCurrentItem())
            let moved = try #require(await scanner.scan().first)
            #expect(moved.item.payload.hasSuffix("Moved.app") && moved.matchesCurrentItem())
            try FileManager.default.removeItem(at: URL(fileURLWithPath: moved.item.payload))
            #expect(!moved.matchesCurrentItem())
            #expect(try await scanner.scan().isEmpty)
        }
    }

    @Test func samePathReplacementAndDisconnectedSymlinkAreRejected() async throws {
        try await withRoot { root in
            let applications = root.appendingPathComponent("Applications")
            let original = try makeSyntheticApplication("Product", in: applications)
            let scanner = FileSystemApplicationScanner(roots: [applications])
            let before = try #require(await scanner.scan().first)
            try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("OldProduct.app"))
            _ = try makeSyntheticApplication("Product", in: applications)
            #expect(!before.matchesCurrentItem())
            let links = root.appendingPathComponent("Links")
            try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("External.app"), withDestinationURL: original)
            let linkScanner = FileSystemApplicationScanner(roots: [links])
            let linked = try #require(await linkScanner.scan().first)
            try FileManager.default.removeItem(at: applications)
            #expect(!linked.matchesCurrentItem())
            #expect(try await linkScanner.scan().isEmpty)
        }
    }

    @Test func localizedInfoIsReadFreshAndOversizedMetadataIsSkipped() async throws {
        try await withRoot { root in
            let app = try makeSyntheticApplication("Localized", in: root)
            let localized = app.appendingPathComponent("Contents/Resources/en.lproj/InfoPlist.strings")
            try FileManager.default.createDirectory(at: localized.deletingLastPathComponent(), withIntermediateDirectories: true)
            let scanner = FileSystemApplicationScanner(roots: [root])
            for name in ["Synthetic localized first", "Synthetic localized changed"] {
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": name], format: .xml, options: 0).write(to: localized)
                #expect(try await scanner.scan().first?.item.title == name)
            }
            try Data(repeating: 65, count: 1_048_577).write(to: app.appendingPathComponent("Contents/Info.plist"))
            #expect(try await scanner.scan().isEmpty)
        }
    }

    @Test func unboundedAndNonFileRootsAreRejected() async throws {
        for roots in [[URL(fileURLWithPath: "/")], [URL(fileURLWithPath: "/Volumes")], [URL(string: "https://example.invalid")!]] {
            do { _ = try await FileSystemApplicationScanner(roots: roots).scan(); Issue.record("Invalid application roots must fail") }
            catch ApplicationCatalogError.inaccessibleRoot {}
        }
    }

    private func withRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ApplicationScan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ApplicationCatalogTests {
    @Test func staleScanCannotOverwriteNewerResultsOrReportItsLateFailure() async throws {
        for oldFailure in [false, true] {
            try await withFixture { root in
                _ = try makeSyntheticApplication("Before", in: root)
                let old = try await FileSystemApplicationScanner(roots: [root]).scan()
                _ = try makeSyntheticApplication("After", in: root)
                let new = try await FileSystemApplicationScanner(roots: [root]).scan()
                let scanner = HeldApplicationScanner()
                let controlled = ApplicationCatalog(scanner: scanner, roots: [])
                var failures = 0; controlled.onFailure = { failures += 1 }
                controlled.start(observing: false)
                do {
                    try await eventually { await scanner.count == 1 }
                    controlled.refresh()
                    try await eventually { await scanner.count == 2 }
                    try await scanner.complete(2, with: .success(new))
                    try await eventually { controlled.items.count == 2 }
                    try await scanner.complete(1, with: oldFailure ? .failure(ApplicationCatalogError.inaccessibleRoot) : .success(old))
                    await Task.yield()
                    #expect(controlled.items.count == 2 && failures == 0)
                } catch { controlled.stop(); await scanner.close(); throw error }
                controlled.stop(); await scanner.close()
            }
        }
    }

    @Test func stopRejectsLatePublicationAndInvalidatesPreviouslyResolvedApplications() async throws {
        try await withFixture { root in
            let app = try makeSyntheticApplication("Owned", in: root)
            let records = try await FileSystemApplicationScanner(roots: [root]).scan()
            let scanner = HeldApplicationScanner()
            let controlled = ApplicationCatalog(scanner: scanner, roots: [])
            controlled.start(observing: false)
            do {
                try await eventually { await scanner.count == 1 }
                try await scanner.complete(1, with: .success(records))
                try await eventually { controlled.items.count == 1 }
                #expect(try await controlled.validatedURL(for: records[0].item) == app.resolvingSymlinksInPath())
                controlled.refresh(); try await eventually { await scanner.count == 2 }
                controlled.stop()
                try await scanner.complete(2, with: .success([])); await Task.yield()
                #expect(controlled.items.count == 1)
                do { _ = try await controlled.validatedURL(for: records[0].item); Issue.record("Stopped index must reject activation") }
                catch ApplicationCatalogError.unavailable {}
            } catch { controlled.stop(); await scanner.close(); throw error }
            await scanner.close()
        }
    }

    @Test func failedRefreshPreservesCacheButRemovedTargetsCannotLaunch() async throws {
        try await withFixture { root in
            let app = try makeSyntheticApplication("Owned", in: root)
            let original = try await FileSystemApplicationScanner(roots: [root]).scan()
            let scanner = HeldApplicationScanner()
            let controlled = ApplicationCatalog(scanner: scanner, roots: [])
            var failures = 0; controlled.onFailure = { failures += 1 }; controlled.start(observing: false)
            do {
                try await eventually { await scanner.count == 1 }
                try await scanner.complete(1, with: .success(original))
                try await eventually { controlled.items.count == 1 }
                try FileManager.default.removeItem(at: app)
                controlled.refresh(); try await eventually { await scanner.count == 2 }
                try await scanner.complete(2, with: .failure(ApplicationCatalogError.inaccessibleRoot))
                try await eventually { failures == 1 }
                #expect(controlled.items.count == 1)
                do { _ = try await controlled.validatedURL(for: original[0].item); Issue.record("Missing cached target must fail before OS launch") }
                catch ApplicationCatalogError.unavailable {}
                _ = try makeSyntheticApplication("Owned", in: root)
                let recreated = try await FileSystemApplicationScanner(roots: [root]).scan()
                controlled.refresh(); try await eventually { await scanner.count == 3 }
                try await scanner.complete(3, with: .success(recreated))
                try await eventually { (try? await controlled.validatedURL(for: recreated[0].item)) != nil }
            } catch { controlled.stop(); await scanner.close(); throw error }
            controlled.stop(); await scanner.close()
        }
    }

    @Test func anOldActionCannotBorrowTheIdentityOfAReplacementAtTheSamePath() async throws {
        try await withFixture { root in
            let app = try makeSyntheticApplication("Owned", in: root)
            let old = try await FileSystemApplicationScanner(roots: [root]).scan()
            let catalog = ApplicationCatalog(roots: [root]); catalog.start(observing: false); defer { catalog.stop() }
            try await eventually { catalog.items.count == 1 }
            try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("NonAppBackup"))
            _ = try makeSyntheticApplication("Owned", in: root, identifier: "synthetic.replacement")
            catalog.refresh()
            try await eventually { catalog.items.first?.objectRevision != old[0].item.objectRevision }
            let replacement = try #require(catalog.items.first)
            #expect(replacement.id == old[0].item.id && replacement.objectRevision != old[0].item.objectRevision)
            do { _ = try await catalog.validatedURL(for: old[0].item); Issue.record("Old action must not activate its replacement") }
            catch ApplicationCatalogError.unavailable {}
            #expect(try await catalog.validatedURL(for: replacement) == app.resolvingSymlinksInPath())
        }
    }

    @Test func watcherPreparationCannotBlockTheMainActorOrLauncherRefresh() async throws {
        try await withFixture { root in
            _ = try makeSyntheticApplication("Owned", in: root)
            let gate = ObservationPreparationGate()
            let catalog = ApplicationCatalog(roots: [root], observationFactory: { _, _ in gate.prepare(); return nil })
            defer { gate.release(); gate.release(); catalog.stop() }
            var started = ContinuousClock.now
            catalog.start()
            let startDuration = started.duration(to: .now)
            print("KEYDOCK_CATALOG_RESPONSE operation=start elapsed=\(startDuration)")
            #expect(startDuration < .milliseconds(100))
            try await eventually { gate.calls == 1 }
            #expect(!gate.ranOnMainThread && catalog.items.isEmpty)
            gate.release(); try await eventually { catalog.items.count == 1 }
            started = .now; catalog.refreshIfStale(maxAge: .zero)
            let refreshDuration = started.duration(to: .now)
            print("KEYDOCK_CATALOG_RESPONSE operation=refresh elapsed=\(refreshDuration)")
            #expect(refreshDuration < .milliseconds(100))
            try await eventually { gate.calls == 2 }
            #expect(!gate.ranOnMainThread)
            gate.release()
        }
    }

    @Test func enablingObservationAfterInitialCacheClosesTheInstallGap() async throws {
        try await withFixture { root in
            _ = try makeSyntheticApplication("Before", in: root)
            let catalog = ApplicationCatalog(roots: [root], observationFactory: { _, _ in
                _ = try makeSyntheticApplication("InstalledDuringObserverSetup", in: root)
                return nil // 无系统事件补救；观察就绪后的新扫描必须覆盖这段安装窗口。
            })
            catalog.start(observing: false); defer { catalog.stop() }
            try await eventually { catalog.items.count == 1 }
            catalog.start()
            try await eventually { catalog.items.count == 2 }
        }
    }

    @Test func volumeCenterPreparationCannotBlockStartOrStaleRefresh() async throws {
        try await withFixture { root in
            _ = try makeSyntheticApplication("Owned", in: root)
            let gate = ObservationPreparationGate(), center = NotificationCenter()
            let catalog = ApplicationCatalog(roots: [root], observationFactory: { _, _ in nil }, workspaceCenter: { gate.prepare(); return center })
            defer { gate.release(); gate.release(); catalog.stop() }
            var started = ContinuousClock.now; catalog.start()
            #expect(started.duration(to: .now) < .milliseconds(100))
            try await eventually { gate.calls == 1 }
            #expect(!gate.ranOnMainThread && catalog.items.isEmpty)
            gate.release(); try await eventually { catalog.items.count == 1 }
            started = .now; catalog.refreshIfStale(maxAge: .zero)
            #expect(started.duration(to: .now) < .milliseconds(100))
            try await eventually { gate.calls == 2 }
            #expect(!gate.ranOnMainThread)
            gate.release()
        }
    }

    @Test func stoppingDuringVolumePreparationRejectsTheLateCandidate() async throws {
        try await withFixture { root in
            _ = try makeSyntheticApplication("Owned", in: root)
            let gate = ObservationPreparationGate(), center = NotificationCenter()
            let catalog = ApplicationCatalog(roots: [root], observationFactory: { _, _ in nil }, workspaceCenter: { gate.prepare(); return center })
            defer { gate.release(); catalog.stop() }
            var changes = 0; catalog.onChange = { _ in changes += 1 }
            catalog.start(); try await eventually { gate.calls == 1 }
            catalog.stop(); gate.release(); try await eventually { gate.finishedCalls == 1 }
            center.post(name: NSWorkspace.didMountNotification, object: nil)
            await Task.yield()
            #expect(catalog.items.isEmpty && changes == 0 && !gate.ranOnMainThread)
        }
    }

    @Test func stoppedVolumeSignalsCannotRefreshARestartedCatalog() async throws {
        try await withFixture { root in
            _ = try makeSyntheticApplication("Owned", in: root)
            let oldCenter = NotificationCenter(), newCenter = NotificationCenter(), centers = SyntheticWorkspaceCenters()
            let catalog = ApplicationCatalog(roots: [root], observationFactory: { _, _ in nil }, workspaceCenter: {
                centers.next() == 1 ? oldCenter : newCenter
            })
            defer { catalog.stop() }
            var publications = 0; catalog.onChange = { _ in publications += 1 }
            catalog.start(); try await eventually { publications == 1 && centers.calls == 1 }
            // 先排队旧信号，再停止和重启；原代次回调不能取消新准备或触发额外扫描。
            oldCenter.post(name: NSWorkspace.didMountNotification, object: nil)
            catalog.stop(); catalog.start()
            try await eventually { publications == 2 && centers.calls == 2 }
            oldCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)
            try await Task.sleep(for: .milliseconds(350))
            #expect(centers.calls == 2)
            _ = try makeSyntheticApplication("New", in: root)
            newCenter.post(name: NSWorkspace.didMountNotification, object: nil)
            try await eventually { catalog.items.count == 2 && centers.calls == 3 }
        }
    }

    @Test func volumeInvalidationSurvivesDirectoryPreparationFailure() async throws {
        try await withFixture { root in
            _ = try makeSyntheticApplication("Owned", in: root)
            let center = NotificationCenter()
            let catalog = ApplicationCatalog(roots: [root], observationFactory: { _, _ in throw ApplicationDirectoryObserverError.unavailable }, workspaceCenter: { center })
            defer { catalog.stop() }
            var failures = 0; catalog.onFailure = { failures += 1 }
            catalog.start(); try await eventually { catalog.items.count == 1 && failures == 1 }
            _ = try makeSyntheticApplication("AfterFailure", in: root)
            center.post(name: NSWorkspace.didMountNotification, object: nil)
            try await eventually { catalog.items.count == 2 && failures == 2 }
        }
    }

    @Test func stoppingVolumeObservationRejectsAlreadyQueuedAndFutureSignals() async throws {
        let center = NotificationCenter(); var calls = 0
        let stopped = ApplicationVolumeObservation(center: center) { calls += 1 }
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        stopped.stop(); stopped.stop(); await Task.yield()
        #expect(calls == 0)
        let active = ApplicationVolumeObservation(center: center) { calls += 1 }
        defer { active.stop() }
        center.post(name: NSWorkspace.didUnmountNotification, object: nil)
        try await eventually { calls == 1 }
        active.stop(); center.post(name: NSWorkspace.didMountNotification, object: nil); await Task.yield()
        #expect(calls == 1)
    }

    @Test func realDirectoryEventsRefreshNestedChangesAndRecreatedRoot() async throws {
        try await withFixture { parent in
            let root = parent.appendingPathComponent("Applications")
            let initial = try makeSyntheticApplication("Before", in: root)
            let catalog = ApplicationCatalog(roots: [root]); catalog.start(); defer { catalog.stop() }
            try await eventually { catalog.items.count == 1 }
            let moved = root.appendingPathComponent("Nested/Moved.app")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: initial, to: moved)
            try await eventually { catalog.items.first?.payload == moved.resolvingSymlinksInPath().path }
            try FileManager.default.removeItem(at: root)
            try await eventually { catalog.items.isEmpty }
            let recreated = try makeSyntheticApplication("Recreated", in: root)
            try await eventually { catalog.items.first?.payload == recreated.resolvingSymlinksInPath().path }
        }
    }

    private func withFixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ApplicationCatalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 { if await condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        throw ApplicationFixtureError.deadline
    }
}

private final class ObservationPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var finished = 0
    private var mainThread = false
    var calls: Int { lock.withLock { count } }
    var finishedCalls: Int { lock.withLock { finished } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }
    func prepare() {
        lock.withLock { count += 1; mainThread = mainThread || Thread.isMainThread }
        _ = semaphore.wait(timeout: .now() + 2)
        lock.withLock { finished += 1 }
    }
    func release() { semaphore.signal() }
}

private final class SyntheticWorkspaceCenters: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private actor HeldApplicationScanner: ApplicationScanning {
    var count = 0
    private var requests: [Int: CheckedContinuation<[ApplicationReference], Error>] = [:]
    func scan() async throws -> [ApplicationReference] {
        count += 1; let id = count
        return try await withCheckedThrowingContinuation { requests[id] = $0 }
    }
    func complete(_ id: Int, with result: Result<[ApplicationReference], Error>) throws {
        guard let continuation = requests.removeValue(forKey: id) else { throw ApplicationFixtureError.missingCall }
        continuation.resume(with: result)
    }
    func close() { for request in requests.values { request.resume(throwing: CancellationError()) }; requests = [:] }
}
