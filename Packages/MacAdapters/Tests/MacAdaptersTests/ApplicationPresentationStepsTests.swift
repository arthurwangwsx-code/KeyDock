import Testing
@testable import MacAdapters

@Suite(.serialized) @MainActor
struct ApplicationPresentationStepsTests {
    @Test func negativeUnhideDoesNotSkipTheApprovedActivation() {
        var order: [String] = []
        let outcome = ApplicationPresentationSteps.perform(needsUnhide: true, validate: { true }, unhide: { order.append("unhide"); return false }, activate: { order.append("activate"); return true })
        #expect(outcome == .accepted && order == ["unhide", "activate"])
    }
    @Test func anUnhiddenApplicationIsActivatedWithoutAnotherUnhide() {
        var calls = 0
        let outcome = ApplicationPresentationSteps.perform(needsUnhide: false, validate: { true }, unhide: { Issue.record("Must not unhide"); return false }, activate: { calls += 1; return true })
        #expect(outcome == .accepted && calls == 1)
    }
    @Test func initialInvalidationDoesNotDispatch() {
        let outcome = ApplicationPresentationSteps.perform(needsUnhide: true, validate: { false }, unhide: { Issue.record("Must not unhide"); return false }, activate: { Issue.record("Must not activate"); return false })
        #expect(outcome == .rejected)
    }
    @Test func cancellationBetweenStepsDoesNotActivate() throws {
        let lease = DesktopOperationLease(); try lease.begin()
        var calls = 0
        let outcome = ApplicationPresentationSteps.perform(needsUnhide: true, validate: { lease.isCurrent }, unhide: { calls += 1; lease.revoke(); return true }, activate: { Issue.record("Must not activate"); return true })
        #expect(outcome == .partial && calls == 1)
    }
    @Test func bothRejectionsAreNotRetried() {
        var calls = 0
        let outcome = ApplicationPresentationSteps.perform(needsUnhide: true, validate: { true }, unhide: { calls += 1; return false }, activate: { calls += 1; return false })
        #expect(outcome == .rejected && calls == 2)
    }
    @Test func acceptedUnhideAndRejectedActivationRemainPartial() {
        let outcome = ApplicationPresentationSteps.perform(needsUnhide: true, validate: { true }, unhide: { true }, activate: { false })
        #expect(outcome == .partial)
    }
}
