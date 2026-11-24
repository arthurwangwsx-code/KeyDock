import Testing
import KeyDockUI

@Suite(.serialized) @MainActor struct VisualReviewEligibilityTests {
    @Test func regularOrIncompleteBuildIdentityCannotEnableSamples() {
        let cases: [(Bool, Bool, String?, String?)] = [
            (false, true, "example.KeyDock.preview", "preview"),
            (true, false, "example.KeyDock.preview", "preview"),
            (true, true, "example.KeyDock", "preview"),
            (true, true, "example.KeyDock.preview", "release"),
            (true, true, nil, "preview"),
            (true, true, "example.KeyDock.preview", nil)
        ]
        for (compiled, isolated, identifier, profile) in cases {
            let state = KDVisualReviewState(previewBuild: compiled, isolatedPreview: isolated, bundleIdentifier: identifier, buildProfile: profile)
            state.select(.all)
            #expect(!state.allowsChanges && state.preset == .system && state.options.isEmpty)
        }
    }
    @Test func eligibleProcessResetsSamplesWithoutWeakeningSystemNeeds() {
        let state = KDVisualReviewState(previewBuild: true, isolatedPreview: true, bundleIdentifier: "example.KeyDock.preview", buildProfile: "preview")
        state.select(.all)
        #expect(state.allowsChanges && state.options == [.higherContrast, .opaqueSurfaces, .reducedMotion])
        state.select(.system)
        #expect(state.options.isEmpty)
        #expect(state.options.increasesContrast(system: .increased))
        #expect(state.options.usesOpaqueSurfaces(system: true) && state.options.reducesMotion(system: true))
    }
}
