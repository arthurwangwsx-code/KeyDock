import Foundation
import Testing
@testable import MacAdapters

@Suite @MainActor struct DesktopReviewLaunchTests {
    let commit = String(repeating: "a", count: 40)
    func metadata(profile: String = "desktop-review", dirty: Bool = false) throws -> Data {
        let binding = DesktopReviewBuildBinding(rootParent: "/synthetic", reviewBundleIdentifier: DesktopReviewScope.bundleIdentifier,
            fixtureBundleIdentifier: DesktopReviewScope.fixtureBundleIdentifier, fixtureAppPath: "/synthetic/Fixture.app",
            fixtureBinarySHA256: String(repeating: "b", count: 64), fixtureInfoSHA256: String(repeating: "c", count: 64))
        return try JSONSerialization.data(withJSONObject: ["profile": profile, "architecture": "arm64",
            "source": ["commit": commit, "dirty": dirty], "desktopReview": JSONSerialization.jsonObject(with: JSONEncoder().encode(binding))])
    }
    @Test func signedProfileBindingIsRequired() throws {
        let args = ["KeyDockDesktopReview", "--desktop-review-root", "/synthetic/KeyDock-DesktopReview-" + UUID().uuidString]
        let result = try DesktopReviewLaunch.parse(arguments: args, bundleIdentifier: DesktopReviewScope.bundleIdentifier, safeSmoke: true, metadata: metadata(), infoCommit: commit)
        #expect(result.root.path == args[2])
        for data in [try metadata(profile: "release"), try metadata(profile: "preview"), try metadata(dirty: true)] {
            #expect(throws: DesktopReviewError.invalidScope) { try DesktopReviewLaunch.parse(arguments: args, bundleIdentifier: DesktopReviewScope.bundleIdentifier, safeSmoke: true, metadata: data, infoCommit: commit) }
        }
        #expect(throws: DesktopReviewError.invalidScope) { try DesktopReviewLaunch.parse(arguments: args, bundleIdentifier: "com.arthurwangwsx.KeyDock", safeSmoke: true, metadata: metadata(), infoCommit: commit) }
        #expect(throws: DesktopReviewError.invalidScope) { try DesktopReviewLaunch.parse(arguments: args, bundleIdentifier: DesktopReviewScope.bundleIdentifier, safeSmoke: false, metadata: metadata(), infoCommit: commit) }
    }
    @Test(arguments: [[], ["--safe-smoke"], ["--desktop-review-root"], ["--desktop-review-root", "relative"], ["--desktop-review-root", "/synthetic/../escape"], ["--desktop-review-root", "/synthetic", "--demo-clipboard"]])
    func argumentsNeverFallBack(_ flags: [String]) throws {
        #expect(throws: DesktopReviewError.invalidScope) { try DesktopReviewLaunch.parse(arguments: ["App"] + flags, bundleIdentifier: DesktopReviewScope.bundleIdentifier, safeSmoke: true, metadata: metadata(), infoCommit: commit) }
    }
}
