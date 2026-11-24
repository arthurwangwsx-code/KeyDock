import Foundation
import Testing
import CommandCore
import ExecutionCore
import MacAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor
struct DesktopActionHostTests {
    @Test func restoredRequestsKeepTheirMeaningWithoutReplaying() async throws {
        let fixture = try RetentionFixture()
        let cases: [(String, LocalizedNotice)] = [
            ("desktop.quitRequested", noticeKey("Quit was requested once. The application may be waiting for you to save; check it before retrying.")),
            ("desktop.windowsRequested", noticeKey("macOS accepted the request to bring all application windows forward. Check their arrangement; minimized windows and Spaces were not individually verified.")),
            ("desktop.unknown", noticeKey("Previous execution was interrupted. Outcome is unknown; it was not replayed."))
        ]
        for (message, expected) in cases {
            let id = UUID()
            fixture.store.restoreReceipt(InvocationReceipt(id: id, name: "Desktop action", state: .interrupted, finishedAt: Date(), message: message))
            let row = try #require(fixture.store.tasks.first { $0.id == id })
            #expect(row.titleKey == "Desktop action" && row.noticeMessage == expected)
            #expect(!row.canCancel && row.restoredFromReceipt && row.output.isEmpty)
        }
        #expect(fixture.store.taskHandles.isEmpty && fixture.store.desktopLeases.isEmpty)
        await fixture.cleanup()
    }
    @Test func definitionChangesRevokeInFlightLeasesAndKeepTypedEffects() async throws {
        let fixture = try RetentionFixture()
        let action = try SavedApplicationAction(name: "Synthetic hide", applicationID: "app./Applications/Synthetic.app", behavior: .hide)
        let lease = DesktopOperationLease(); try lease.begin(); try lease.markSubmission()
        fixture.store.desktopLeases[UUID()] = lease
        #expect(fixture.store.saveApplicationAction(action))
        #expect(!lease.isCurrent && lease.didSubmit)
        let item = try #require(fixture.store.catalog.first { $0.id == "application-action." + action.id.uuidString })
        #expect(ShortcutCategory.applications.contains(item) && !ShortcutCategory.tools.contains(item))
        let descriptor = try fixture.store.descriptor(for: item)
        #expect(descriptor.actions[0].effects == [.changeApplicationVisibility])
        fixture.store.deleteApplicationAction(action.id)
        #expect(fixture.store.applicationActions.isEmpty && !fixture.store.catalog.contains { $0.id == item.id })
        await fixture.cleanup()
    }
}
