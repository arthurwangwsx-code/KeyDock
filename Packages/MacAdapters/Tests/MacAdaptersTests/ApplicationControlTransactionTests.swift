import Foundation
import Testing
import CommandCore
@testable import MacAdapters

@Suite(.serialized) @MainActor
struct ApplicationControlTransactionTests {
    @Test func toggleUsesInvocationForegroundInsteadOfLaterState() async throws {
        var calls: [ApplicationBehavior] = []
        var current = ApplicationControlState(exists: true, active: false)
        let port = ApplicationControlTransaction(validate: {}, state: { current }, dispatch: { action in
            calls.append(action); current = .init(exists: true, hidden: true); return .accepted
        })
        let outcome = try await port.run(.toggleVisibility, wasFrontmost: true, lease: DesktopOperationLease())
        #expect(outcome == .confirmed && calls == [.hide])
    }
    @Test func normalQuitWaitsForActualTerminationAndDoesNotRetry() async throws {
        var calls = 0
        let lease = DesktopOperationLease()
        let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: true) }, dispatch: { _ in calls += 1; return .accepted })
        let outcome = try await port.run(.requestQuit, wasFrontmost: false, lease: lease, timeout: .milliseconds(1))
        #expect(outcome == .requestSubmitted && calls == 1 && lease.didSubmit)
        await #expect(throws: (any Error).self) { try await port.run(.requestQuit, wasFrontmost: false, lease: lease) }
        #expect(calls == 1)
    }
    @Test func quitIsConfirmedOnlyWhenThatInstanceDisappears() async throws {
        var exists = true
        let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: exists) }, dispatch: { _ in exists = false; return .accepted })
        #expect(try await port.run(.requestQuit, wasFrontmost: false, lease: DesktopOperationLease()) == .confirmed)
    }
    @Test func validationCancellationNeverDispatches() async throws {
        var calls = 0
        let lease = DesktopOperationLease()
        let port = ApplicationControlTransaction(validate: { lease.revoke(); await Task.yield() }, state: { .init(exists: true) }, dispatch: { _ in calls += 1; return .accepted })
        await #expect(throws: CancellationError.self) { try await port.run(.show, wasFrontmost: false, lease: lease) }
        #expect(calls == 0 && !lease.didSubmit)
    }
    @Test func cancellationAfterDispatchRetainsUnknownEvidence() async throws {
        let lease = DesktopOperationLease()
        var calls = 0
        let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: true) }, dispatch: { _ in calls += 1; lease.revoke(); return .accepted })
        await #expect(throws: CancellationError.self) { try await port.run(.show, wasFrontmost: false, lease: lease) }
        #expect(calls == 1 && lease.didSubmit)
    }
    @Test func rejectedAndPartialRequestsHaveDifferentOutcomes() async throws {
        for (dispatch, expected) in [(ApplicationDispatchResult.rejected, DesktopControlOutcome.declined), (.partial, .outcomeUnknown)] {
            var calls = 0
            let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: true) }, dispatch: { _ in calls += 1; return dispatch })
            #expect(try await port.run(.show, wasFrontmost: false, lease: DesktopOperationLease(), timeout: .milliseconds(1)) == expected)
            #expect(calls == 1)
        }
    }
    @Test func missingHideAndQuitAreNoOpsAndNeverLaunch() async throws {
        for action in [ApplicationBehavior.hide, .requestQuit] {
            let lease = DesktopOperationLease()
            let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: false) }, dispatch: { _ in Issue.record("Must not dispatch"); return .accepted })
            #expect(try await port.run(action, wasFrontmost: false, lease: lease) == .noOp)
            #expect(!lease.didSubmit)
        }
    }
    @Test func acceptedButUnobservedShowStaysUnknown() async throws {
        let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: true) }, dispatch: { _ in .accepted })
        #expect(try await port.run(.show, wasFrontmost: false, lease: DesktopOperationLease(), timeout: .milliseconds(1)) == .outcomeUnknown)
    }
    @Test func negativeAcknowledgementStillAllowsObservedPostconditionWithoutRetry() async throws {
        var calls = 0, reads = 0
        let port = ApplicationControlTransaction(validate: {}, state: {
            reads += 1; return .init(exists: true, hidden: reads >= 3)
        }, dispatch: { _ in calls += 1; return .rejected })
        let result = try await port.run(.hide, wasFrontmost: false, lease: DesktopOperationLease(), timeout: .milliseconds(200))
        #expect(result == .confirmed && calls == 1 && reads >= 3)
    }
    @Test func allWindowsRequestCannotBeConfirmedFromActivationAlone() async throws {
        for acknowledgement in [ApplicationDispatchResult.accepted, .rejected] {
            let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: true, active: true) }, dispatch: { _ in acknowledgement })
            let result = try await port.run(.showAllWindows, wasFrontmost: false, lease: DesktopOperationLease())
            #expect(result == (acknowledgement == .accepted ? .requestSubmitted : .outcomeUnknown))
        }
    }
    @Test func observedPartialChangeCannotBeReportedAsAnUnchangedRejection() async throws {
        var hidden = true
        let port = ApplicationControlTransaction(validate: {}, state: { .init(exists: true, hidden: hidden, active: false) }, dispatch: { _ in hidden = false; return .rejected })
        let result = try await port.run(.show, wasFrontmost: false, lease: DesktopOperationLease(), timeout: .milliseconds(1))
        #expect(result == .outcomeUnknown)
    }
}
