import Foundation
import Testing
import MacAdapters
import KeyDockUI
@testable import WorkbenchFeature

@MainActor private final class PreferenceClipboardSource: ClipboardCaptureSource {
    var changeCount = 0
    var availableTypes = ["public.utf8-plain-text"]
    var sourceApplication: String? = "synthetic.preference-source"
    var bodyReads = 0
    func readText() -> String? { bodyReads += 1; return "Synthetic clipboard " + String(changeCount) }
}

/// 真实 Store/monitor 与注入的纯内存来源；不读取系统剪贴板、选区或凭据。
@Suite(.serialized) @MainActor struct ClipboardPreferencesTests {
    private func withStore(_ body: (WorkbenchModel, InterfaceWriteRelay, PreferenceClipboardSource, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-ClipboardPreferences-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let relay = InterfaceWriteRelay(), source = PreferenceClipboardSource()
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: true,
            clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in }, configurationWriter: relay.write,
            applicationCatalog: ApplicationCatalog(roots: []), clipboardCaptureSource: source, languageApplier: { _ in })
        do { try await body(store, relay, source, directory); await store.shutdownAndWait() }
        catch { await store.shutdownAndWait(); try? FileManager.default.removeItem(at: directory); throw error }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func pauseStopsBodyReadsEvenWhenTheSavedRecordingPreferenceCannotChange(failure: InterfaceWriteRelay.Failure) async throws {
        try await withStore { store, relay, source, directory in
            #expect(store.setClipboardRecording(true))
            source.changeCount += 1; await store.monitor.poll(); #expect(source.bodyReads == 1)
            relay.failure = failure
            #expect(!store.setClipboardRecording(false))
            #expect(!store.configuration.clipboardEnabled && store.clipboardPauseNeedsPersistence)
            #expect(!store.clipboardCaptureNotice.isEmpty)
            source.changeCount += 1; await store.monitor.poll(); #expect(source.bodyReads == 1)
            let file = directory.appendingPathComponent("configuration.json")
            let previous = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: file))
            #expect(previous.clipboardEnabled)
            relay.failure = .before; store.save()
            #expect(store.clipboardPauseNeedsPersistence)
            store.save()
            #expect(!store.clipboardPauseNeedsPersistence)
            let paused = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: file))
            #expect(!paused.clipboardEnabled)
            source.changeCount += 1; await store.monitor.poll(); #expect(source.bodyReads == 1)
        }
    }

    @Test(arguments: [InterfaceWriteRelay.Failure.before, .after])
    func failedEnableAndExclusionChangeStayPausedUntilSuccessfulExplicitEnable(failure: InterfaceWriteRelay.Failure) async throws {
        try await withStore { store, relay, source, _ in
            #expect(store.setClipboardRecording(false))
            relay.failure = failure
            #expect(!store.setClipboardRecording(true))
            source.changeCount += 1; await store.monitor.poll(); #expect(source.bodyReads == 0)
            #expect(store.setClipboardRecording(true))
            source.changeCount += 1; await store.monitor.poll(); #expect(source.bodyReads == 1)
            let previousExclusions = store.configuration.clipboardExclusions
            relay.failure = failure
            #expect(!store.saveClipboardExclusions(["synthetic.preference-source"]))
            #expect(store.configuration.clipboardExclusions == previousExclusions && !store.configuration.clipboardEnabled)
            source.changeCount += 1; await store.monitor.poll(); #expect(source.bodyReads == 1)
            #expect(store.saveClipboardExclusions(["synthetic.preference-source"]))
            #expect(!store.clipboardPauseNeedsPersistence && !store.configuration.clipboardEnabled)
            #expect(store.setClipboardRecording(true))
            source.changeCount += 1; await store.monitor.poll(); #expect(source.bodyReads == 1) // 新排除策略在读正文前生效。
        }
    }
}
