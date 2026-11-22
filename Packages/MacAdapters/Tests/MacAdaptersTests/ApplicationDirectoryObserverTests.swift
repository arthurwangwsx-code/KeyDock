import Foundation
import Testing
@testable import MacAdapters

/// 全部事件来自本测试创建的临时目录，不访问Applications或用户文件正文。
@Suite(.serialized) @MainActor struct ApplicationDirectoryObserverTests {
    @Test func recursiveChangesInvalidateAndStoppedObserverRemainsSilent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("Synthetic/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        var signals = 0
        let observer = try ApplicationDirectoryObserver(roots: [root]) { signals += 1 }
        defer { observer.stop() }
        try await Task.sleep(for: .milliseconds(500))
        var baseline = signals
        let item = deep.appendingPathComponent("Synthetic.app", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        #expect(await eventually { signals > baseline })
        baseline = signals
        let renamed = deep.appendingPathComponent("Renamed.app", isDirectory: true)
        try FileManager.default.moveItem(at: item, to: renamed)
        #expect(await eventually { signals > baseline })
        baseline = signals
        try FileManager.default.removeItem(at: renamed)
        #expect(await eventually { signals > baseline })
        observer.stop(); observer.stop()
        baseline = signals
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(700))
        #expect(signals == baseline)
    }

    @Test func missingRootUsesNearestExistingParentAndDetectsItsCreation() async throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Missing/Applications", isDirectory: true)
        var signals = 0
        let observer = try ApplicationDirectoryObserver(roots: [root, root]) { signals += 1 }
        defer { observer.stop() }
        #expect(observer.watchedDirectories == [parent.resolvingSymlinksInPath()])
        try await Task.sleep(for: .milliseconds(500))
        let baseline = signals
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(await eventually { signals > baseline })
    }

    @Test func queuedSignalsCannotWakeAfterDeactivation() async throws {
        var signals = 0
        let context = ApplicationDirectorySignal { signals += 1 }
        context.enqueue(); context.enqueue()
        context.deactivate()
        try await Task.sleep(for: .milliseconds(50))
        context.enqueue()
        try await Task.sleep(for: .milliseconds(50))
        #expect(signals == 0)
    }

    @Test func deinitializationReleasesTheStreamOwnedCallback() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        weak var retained: SyntheticCallbackLifetime?
        do {
            let probe = SyntheticCallbackLifetime(); retained = probe
            var observer: ApplicationDirectoryObserver? = try ApplicationDirectoryObserver(roots: [root]) { [probe] in probe.signals += 1 }
            #expect(observer != nil)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Synthetic.app"), withIntermediateDirectories: true)
            observer = nil
        }
        #expect(await eventually { retained == nil })
    }

    @Test func invalidOrUnboundedRootsAreRejected() throws {
        for roots in [[], [URL(fileURLWithPath: "/")], [URL(string: "https://example.invalid")!], Array(repeating: URL(fileURLWithPath: "/tmp"), count: 17)] {
            #expect(throws: ApplicationDirectoryObserverError.invalidRoots) {
                try ApplicationDirectoryObserver(roots: roots) {}
            }
        }
    }

    @Test func symlinkToVolumeRootCannotExpandIntoAWholeDiskWatch() throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let link = parent.appendingPathComponent("SyntheticRoot")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/"))
        #expect(throws: ApplicationDirectoryObserverError.invalidRoots) {
            try ApplicationDirectoryObserver(roots: [link]) {}
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Observer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}

@MainActor private final class SyntheticCallbackLifetime { var signals = 0 }
