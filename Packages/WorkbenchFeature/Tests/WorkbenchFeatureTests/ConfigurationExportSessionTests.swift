import Foundation
import Testing
import AutomationCore
@testable import WorkbenchFeature

private actor ExportCaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Suite(.serialized) struct ConfigurationExportSessionTests {
    @Test(arguments: ["configuration", "clipboard", "desktop"])
    func crossAwaitABAMutationsRequireExplicitRefresh(_ owner: String) async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let gate = ExportCaptureGate()
            let capture = Task { try await fixture.store.captureConfigurationExport(sections: [.schedules], sourceVersion: "synthetic", scheduleReader: {
                await gate.wait(); return .init(generation: UUID(), definitions: [])
            }) }
            try await fixture.eventually { await gate.entered }
            switch owner {
            case "configuration":
                let old = fixture.store.configuration.language
                fixture.store.configuration.language = "en"; fixture.store.configuration.language = old
            case "clipboard":
                let old = fixture.store.clipboardPreferences.separator
                fixture.store.clipboardPreferences.separator = .newline; fixture.store.clipboardPreferences.separator = old
            default:
                fixture.store.applicationActionsWritable = false; fixture.store.applicationActionsWritable = true
            }
            await gate.release()
            do { _ = try await capture.value; Issue.record("Expected generation conflict") }
            catch { #expect(error as? ConfigurationExportError == .snapshotChanged) }
            await fixture.assertNoExecution()
        }
    }
    @Test func captureOnlyReadsLoadedDefinitionsAndRetainsFrozenBytes() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let path = fixture.directory.appendingPathComponent("configuration.json")
            let before = try Data(contentsOf: path)
            let ledgerBefore = await fixture.store.scheduleLedger.snapshots()
            let source = try await fixture.store.captureConfigurationExport(sections: Set(ConfigurationExportSection.allCases), sourceVersion: "synthetic")
            let frozen = try ConfigurationExportProjection.make(source: source, sections: Set(ConfigurationExportSection.allCases))
            fixture.store.configuration.language = "zh-Hans"
            #expect(frozen.data == (try ConfigurationExportProjection.make(source: source, sections: Set(ConfigurationExportSection.allCases))).data)
            #expect(try Data(contentsOf: path) == before)
            #expect(await fixture.store.scheduleLedger.snapshots() == ledgerBefore)
            await fixture.assertNoExecution()
            fixture.store.desktopWorkspacesWritable = false
            let unavailable = try await fixture.store.captureConfigurationExport(sections: [.desktop], sourceVersion: "synthetic")
            #expect(throws: ConfigurationExportError.unavailableSource("desktop")) { try ConfigurationExportProjection.make(source: unavailable, sections: [.desktop]) }
        }
    }
    @Test func optionalScheduleReadIsSkippedAndShutdownRejectsLateCapture() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            _ = try await fixture.store.captureConfigurationExport(sections: [.preferences], sourceVersion: "synthetic", scheduleReader: {
                Issue.record("Unselected schedule owner must not be read"); return .init(generation: UUID(), definitions: [])
            })
            let gate = ExportCaptureGate()
            let capture = Task { try await fixture.store.captureConfigurationExport(sections: [.schedules], sourceVersion: "synthetic", scheduleReader: {
                await gate.wait(); return .init(generation: UUID(), definitions: [])
            }) }
            try await fixture.eventually { await gate.entered }
            await fixture.store.shutdownAndWait(); await gate.release()
            do { _ = try await capture.value; Issue.record("Shutdown must reject capture") } catch { #expect(error is CancellationError) }
        }
    }
    @Test func closeAndChoiceChangesRejectAnEncoderThatIgnoresCancellation() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let source = try ConfigurationExportFixture.source(), gate = ExportCaptureGate()
            let presentation = ConfigurationExportPresentation()
            presentation.refresh(capture: { _ in source }, encode: { source, sections in
                await gate.wait(); return try ConfigurationExportProjection.make(source: source, sections: sections)
            })
            try await fixture.eventually { await gate.entered }
            presentation.setSection(.resources, selected: false)
            presentation.refresh(capture: { _ in source })
            try await fixture.eventually { presentation.canSave }
            let accepted = try #require(presentation.snapshot)
            await gate.release()
            try await Task.sleep(for: .milliseconds(30))
            #expect(presentation.snapshot?.id == accepted.id && presentation.snapshot?.sections.contains(.resources) == false)
            let closingGate = ExportCaptureGate()
            presentation.refresh(capture: { _ in await closingGate.wait(); return source })
            try await fixture.eventually { await closingGate.entered }
            presentation.invalidate(); await closingGate.release()
            try await Task.sleep(for: .milliseconds(30))
            #expect(presentation.invalidated && presentation.snapshot == nil && !presentation.canSave && !presentation.isCapturing)
        }
    }
    @Test func saveAttemptOwnershipChoiceABAAndFailureKeepReviewedBytes() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let source = try ConfigurationExportFixture.source(), presentation = ConfigurationExportPresentation()
            presentation.refresh(capture: { _ in source })
            try await fixture.eventually { presentation.canSave }
            let old = try #require(presentation.snapshot), attempt = try #require(presentation.beginSave())
            #expect(attempt.snapshot.data == old.data && presentation.beginSave() == nil)
            presentation.setSection(.resources, selected: false)
            #expect(presentation.sections == old.sections)
            #expect(!presentation.finishSave(UUID(), outcome: .saved))
            #expect(presentation.finishSave(attempt.id, outcome: .failed) && presentation.canSave && presentation.snapshot?.data == old.data)
            let retry = try #require(presentation.beginSave())
            #expect(retry.id != attempt.id && retry.snapshot.data == attempt.snapshot.data)
            #expect(!presentation.finishSave(attempt.id, outcome: .saved))
            #expect(presentation.finishSave(retry.id, outcome: .cancelled))
            presentation.setSection(.resources, selected: false); presentation.setSection(.resources, selected: true)
            #expect(!presentation.previewIsCurrent && !presentation.canSave && presentation.snapshot?.data == old.data)
            presentation.refresh(capture: { _ in source })
            try await fixture.eventually { presentation.canSave }
            presentation.invalidate()
            #expect(!presentation.finishSave(retry.id, outcome: .saved) && presentation.snapshot == nil)
        }
    }
    @Test func sheetOwnershipBlocksEditorsUntilDismissAndRejectsOldCallbacks() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let session = SettingsSession(store: fixture.store)
            session.prepareConfigurationExport(in: fixture.store)
            let old = try #require(session.configurationExport)
            session.configurationExportDidAppear(old.id)
            try await fixture.eventually { old.canSave }
            session.prepareSettingsSummary(in: fixture.store); session.beginNewCommand()
            #expect(session.settingsSummaryExport == nil && session.editedCommand == nil)
            let attempt = try #require(old.beginSave())
            session.closeConfigurationExport(old.id)
            #expect(session.configurationExport?.id == old.id && !old.invalidated)
            session.finishConfigurationExportSave(old.id, attemptID: attempt.id, outcome: .cancelled)
            session.closeConfigurationExport(old.id)
            #expect(old.invalidated && session.configurationExportDismissing && !session.canBeginSavedItemEditor)
            session.configurationExportDidDismiss(old.id)
            #expect(session.canBeginSavedItemEditor)
            session.prepareConfigurationExport(in: fixture.store)
            let current = try #require(session.configurationExport)
            session.configurationExportDidDismiss(old.id)
            session.finishConfigurationExportSave(old.id, attemptID: attempt.id, outcome: .saved)
            #expect(session.configurationExport?.id == current.id)
            session.setVisible(false)
            #expect(current.invalidated && session.configurationExport == nil)
        }
    }
}
