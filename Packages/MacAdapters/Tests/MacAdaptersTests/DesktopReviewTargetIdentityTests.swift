import Foundation
import Testing
@testable import MacAdapters

@Suite struct DesktopReviewTargetIdentityTests {
    let expected = DesktopReviewProcessIdentity(pid: 42424, launchTime: 1234.5,
        bundleIdentifier: "synthetic.bound.fixture", appPath: "/Synthetic/Bound.app", executablePath: "/Synthetic/Bound.app/Contents/MacOS/Fixture")
    @Test func completeMatchingSnapshotIsAccepted() {
        #expect(DesktopReviewTargetIdentityCheck.failure(expected: expected, actual: .init(expected)) == nil)
        #expect(DesktopReviewTargetIdentityCheck.failure(expected: expected, actual: nil) == .applicationUnavailable)
    }
    @Test(arguments: [DesktopReviewTargetDiagnostic.applicationTerminated, .pidChanged, .launchDateUnavailable, .launchDateChanged,
                      .bundleIdentifierUnavailable, .bundleIdentifierChanged, .bundlePathUnavailable, .bundlePathChanged,
                      .executablePathUnavailable, .executablePathChanged])
    func missingAndChangedFieldsRemainDistinct(_ reason: DesktopReviewTargetDiagnostic) {
        var actual = DesktopReviewProcessSnapshot(expected)
        switch reason {
        case .applicationTerminated: actual.isTerminated = true
        case .pidChanged: actual.pid += 1
        case .launchDateUnavailable: actual.launchTime = nil
        case .launchDateChanged: actual.launchTime = expected.launchTime + 1
        case .bundleIdentifierUnavailable: actual.bundleIdentifier = nil
        case .bundleIdentifierChanged: actual.bundleIdentifier = "synthetic.other.fixture"
        case .bundlePathUnavailable: actual.appPath = nil
        case .bundlePathChanged: actual.appPath = "/Synthetic/Other.app"
        case .executablePathUnavailable: actual.executablePath = nil
        case .executablePathChanged: actual.executablePath = "/Synthetic/Other.app/Contents/MacOS/Fixture"
        case .applicationUnavailable: Issue.record("This case requires a missing snapshot")
        }
        #expect(DesktopReviewTargetIdentityCheck.failure(expected: expected, actual: actual) == reason)
    }
    @Test(arguments: [Double.nan, .infinity, 0, -1])
    func unusableLaunchDatesNeverAuthorizeAnInstance(_ date: Double) {
        var actual = DesktopReviewProcessSnapshot(expected); actual.launchTime = date
        #expect(DesktopReviewTargetIdentityCheck.failure(expected: expected, actual: actual) == .launchDateUnavailable)
    }
}
