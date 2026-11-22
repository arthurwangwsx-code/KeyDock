import Foundation
import Testing
@testable import MacAdapters

/// 缺失目录只观察最近父目录的条目；所有目录与正文均为测试自建合成数据。
@Suite(.serialized) @MainActor struct ApplicationDirectoryParentObserverTests {
    @Test func unrelatedDescendantContentWritesDoNotInvalidateMissingRoot() async throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let unrelated = parent.appendingPathComponent("Unrelated/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let file = unrelated.appendingPathComponent("synthetic.txt")
        try Data("before".utf8).write(to: file)
        var signals = 0
        let observer = try ApplicationDirectoryObserver(roots: [parent.appendingPathComponent("Missing/Applications")]) { signals += 1 }
        defer { observer.stop() }
        try await Task.sleep(for: .milliseconds(500))
        let baseline = signals
        for index in 0..<3 {
            try Data("synthetic-\(index)".utf8).write(to: file, options: .atomic)
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(signals == baseline)
    }

    @Test func rebuildingObserverFollowsDeepCreationAndThenWatchesApprovedRootRecursively() async throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let intermediate = parent.appendingPathComponent("Missing", isDirectory: true)
        let root = intermediate.appendingPathComponent("Applications", isDirectory: true)
        var signals = 0
        var observer = try ApplicationDirectoryObserver(roots: [root]) { signals += 1 }
        defer { observer.stop() }
        #expect(observer.watchedDirectories == [parent.resolvingSymlinksInPath()])
        var baseline = signals
        try FileManager.default.createDirectory(at: intermediate, withIntermediateDirectories: true)
        #expect(await eventually { signals > baseline })
        observer.stop()
        observer = try ApplicationDirectoryObserver(roots: [root]) { signals += 1 }
        #expect(observer.watchedDirectories == [intermediate.resolvingSymlinksInPath()])
        baseline = signals
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(await eventually { signals > baseline })
        let deep = root.appendingPathComponent("Tools/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        observer.stop()
        observer = try ApplicationDirectoryObserver(roots: [root]) { signals += 1 }
        #expect(observer.watchedDirectories == [root.resolvingSymlinksInPath()])
        try await Task.sleep(for: .milliseconds(500))
        baseline = signals
        try FileManager.default.createDirectory(at: deep.appendingPathComponent("Synthetic.app"), withIntermediateDirectories: true)
        #expect(await eventually { signals > baseline })
    }

    @Test func stoppingParentSourceSuppressesQueuedAndFutureEntryChanges() async throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        var signals = 0
        let observer = try ApplicationDirectoryObserver(roots: [parent.appendingPathComponent("Missing/Applications")]) { signals += 1 }
        try await Task.sleep(for: .milliseconds(500))
        let baseline = signals
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("First"), withIntermediateDirectories: true)
        observer.stop(); observer.stop()
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("Second"), withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(signals == baseline)
    }

    @Test func deinitializingParentSourceReleasesItsCallbackAfterCancellation() async throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        weak var retained: ParentCallbackLifetime?
        do {
            let probe = ParentCallbackLifetime(); retained = probe
            var observer: ApplicationDirectoryObserver? = try ApplicationDirectoryObserver(roots: [parent.appendingPathComponent("Missing/Applications")]) { [probe] in probe.signals += 1 }
            #expect(observer != nil)
            observer = nil
        }
        #expect(await eventually { retained == nil })
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ParentObserver-" + UUID().uuidString, isDirectory: true)
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

@MainActor private final class ParentCallbackLifetime { var signals = 0 }
