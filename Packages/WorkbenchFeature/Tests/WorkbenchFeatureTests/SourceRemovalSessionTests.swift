import Foundation
import Testing
@testable import WorkbenchFeature

@MainActor @Suite(.serialized) struct SourceRemovalSessionTests {
    @Test func staleReviewIDCannotConfirmANewerReview() async throws {
        try await withSourceRemovalFixture { f, relay in
            let value = try makeRemovalWorkflow(in: f), presentation = SourceRemovalPresentation(.workflow(value.id))
            presentation.refresh(in: f.store); try await f.eventually { presentation.canConfirm }
            let old = try #require(presentation.review?.id), writes = relay.writes
            presentation.refresh(in: f.store); try await f.eventually { presentation.canConfirm }
            let current = try #require(presentation.review?.id)
            #expect(old != current)
            presentation.confirm(old, in: f.store)
            #expect(!presentation.isBusy && f.store.configuration.workflows == [value] && relay.writes == writes)
            presentation.confirm(current, in: f.store)
            try await f.eventually { presentation.removed }
            #expect(f.store.configuration.workflows.isEmpty)
        }
    }
    @Test func windowCloseDuringAwaitRejectsConfirmAndReleasesScheduleGate() async throws {
        try await withSourceRemovalFixture { f, relay in
            let value = try makeRemovalWorkflow(in: f), session = WorkspaceSession(), gate = SourceRemovalGate()
            defer { Task { await gate.release() } }
            session.prepareSourceRemoval(.workflow(value.id), in: f.store)
            let presentation = try #require(session.sourceRemoval)
            session.sourceRemovalDidAppear(presentation.id)
            try await f.eventually { presentation.canConfirm }
            let snapshot = await f.store.scheduleLedger.definitionSnapshot(), writes = relay.writes
            presentation.confirm(try #require(presentation.review?.id), in: f.store, scheduleReader: { await gate.wait(); return snapshot })
            try await f.eventually { await gate.entered }
            session.setVisible(false, in: f.store)
            #expect(presentation.invalidated && session.sourceRemovalDismissing && f.store.scheduleBusy)
            await gate.release()
            try await f.eventually { !f.store.scheduleBusy && f.store.configurationOperations.isEmpty }
            #expect(f.store.configuration.workflows == [value] && relay.writes == writes)
            session.sourceRemovalDidDismiss(presentation.id)
            #expect(session.sourceRemoval == nil && session.canPresentSourceRemoval)
        }
    }
    @Test func uncooperativeOldCaptureAndDismissCannotReplaceNewPresentation() async throws {
        try await withSourceRemovalFixture { f, _ in
            let value = try makeRemovalWorkflow(in: f), old = SourceRemovalPresentation(.workflow(value.id)), gate = SourceRemovalGate()
            defer { Task { await gate.release() } }
            let snapshot = await f.store.scheduleLedger.definitionSnapshot()
            let oldCapture = old.refresh(in: f.store, scheduleReader: { await gate.wait(); return snapshot })
            try await f.eventually { await gate.entered }
            old.invalidate()
            let session = WorkspaceSession(); session.prepareSourceRemoval(.workflow(value.id), in: f.store)
            let current = try #require(session.sourceRemoval)
            try await f.eventually { current.canConfirm }
            await gate.release(); await oldCapture?.value
            session.cancelSourceRemoval(old.id); session.sourceRemovalDidDismiss(old.id)
            #expect(old.review == nil && old.invalidated && session.sourceRemoval?.id == current.id && current.canConfirm)
        }
    }
    @Test func settingsModalOwnershipAndFailedSaveRetainTheReviewForRetry() async throws {
        try await withSourceRemovalFixture { f, relay in
            let source = try makeRemovalMCP(in: f), session = SettingsSession(store: f.store)
            session.prepareSourceRemoval(.mcpServer(source.id), in: f.store)
            let presentation = try #require(session.sourceRemoval)
            session.sourceRemovalDidAppear(presentation.id)
            try await f.eventually { presentation.canConfirm }
            session.prepareConfigurationExport(in: f.store); session.prepareSettingsSummary(in: f.store); session.beginNewCommand()
            #expect(session.configurationExport == nil && session.settingsSummaryExport == nil && session.editedCommand == nil)
            let reviewID = try #require(presentation.review?.id)
            relay.failure = .after; presentation.confirm(reviewID, in: f.store)
            try await f.eventually { !presentation.isBusy }
            #expect(!presentation.removed && presentation.canConfirm && presentation.review?.id == reviewID && !presentation.notice.rendered().isEmpty)
            #expect(f.store.configuration.mcpServers == [source] && f.store.mcpSessionDisabled.contains(source.id))
            presentation.confirm(reviewID, in: f.store)
            try await f.eventually { presentation.removed }
            session.sourceRemovalDidDismiss(presentation.id)
            #expect(session.canBeginSavedItemEditor && f.store.configuration.mcpServers.isEmpty)
        }
    }
}
