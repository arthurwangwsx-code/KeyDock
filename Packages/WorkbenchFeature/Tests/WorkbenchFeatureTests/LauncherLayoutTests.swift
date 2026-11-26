import Foundation
import Testing
@testable import WorkbenchFeature

struct LauncherLayoutTests {
    private let query = UUID()
    private func snapshot(_ count: Int? = nil, generation: UInt64 = 1, revision: UInt64 = 0, complete: Bool = true, mode: LauncherLayoutSnapshot.Mode = .search, notices: Int = 0, held: Bool = false) -> LauncherLayoutSnapshot {
        .init(mode: mode, modeRevision: revision, queryID: query, generation: generation, resultCount: count, isComplete: complete, noticeSlots: notices, held: held)
    }
    @Test(arguments: [(0, 306.0), (1, 220.0), (3, 305.0), (7, 456.0), (2000, 456.0), (Int.max, 456.0)])
    func finalCountsUseBoundedDensity(_ entry: (Int, Double)) {
        var state = LauncherLayoutState()
        _ = state.resolve(snapshot(entry.0), maximumHeight: 900)
        let actual: CGFloat = state.currentHeight, expected: CGFloat = CGFloat(entry.1)
        #expect(actual == expected, "Actual \(actual), expected \(expected)")
        #expect(state.resolve(snapshot(entry.0), maximumHeight: 900) == .place(expected))
    }
    @Test func pendingAndPartialCannotShrinkAndOldQueriesCannotOverwriteNewGeometry() {
        var state = LauncherLayoutState()
        #expect(state.resolve(snapshot(1), maximumHeight: 900) == .place(220))
        #expect(state.resolve(snapshot(generation: 2, complete: false), maximumHeight: 900) == .place(220))
        #expect(state.resolve(snapshot(0, generation: 1), maximumHeight: 900) == .rejected)
        #expect(state.resolve(snapshot(3, generation: 2, complete: false), maximumHeight: 900) == .place(305))
        #expect(state.resolve(snapshot(1, generation: 2, complete: false), maximumHeight: 900) == .place(305))
        #expect(state.resolve(snapshot(1, generation: 2), maximumHeight: 900) == .place(220))
        let conflict = LauncherLayoutSnapshot(mode: .search, modeRevision: 0, queryID: UUID(), generation: 2, resultCount: 7, isComplete: true)
        #expect(state.resolve(conflict, maximumHeight: 900) == .rejected && state.currentHeight == 220)
    }
    @Test func heldAndAIRejectLateSearchModesAndReleaseUsesLatestState() {
        var state = LauncherLayoutState()
        _ = state.resolve(snapshot(1), maximumHeight: 900)
        #expect(state.resolve(snapshot(3, revision: 1, held: true), maximumHeight: 900) == .held)
        #expect(state.resolve(snapshot(7, revision: 0), maximumHeight: 900) == .rejected)
        #expect(state.currentHeight == 220)
        #expect(state.resolve(snapshot(3, revision: 2), maximumHeight: 900) == .place(305))
        #expect(state.resolve(snapshot(revision: 3, complete: false, mode: .compactAI), maximumHeight: 900) == .place(456))
        #expect(state.resolve(snapshot(1, revision: 2), maximumHeight: 900) == .rejected)
        #expect(state.resolve(snapshot(generation: 2, revision: 4, complete: false), maximumHeight: 900) == .place(456))
        #expect(state.resolve(snapshot(3, generation: 2, revision: 4), maximumHeight: 900) == .place(305))
    }
    @Test func noticesCanGrowPendingWhileClearWaitsForCompletionAndScreenHeightCapsEverything() {
        var state = LauncherLayoutState()
        _ = state.resolve(snapshot(1), maximumHeight: 900)
        #expect(state.resolve(snapshot(generation: 2, complete: false, notices: 1), maximumHeight: 900) == .place(276))
        #expect(state.resolve(snapshot(generation: 2, complete: false, notices: 0), maximumHeight: 900) == .place(276))
        #expect(state.resolve(snapshot(generation: 2, complete: false, notices: 1), maximumHeight: 900) == .place(276))
        #expect(state.resolve(snapshot(1, generation: 2, notices: 1), maximumHeight: 900) == .place(276))
        #expect(state.resolve(snapshot(1, generation: 2, complete: false), maximumHeight: 900) == .place(276))
        #expect(state.resolve(snapshot(1, generation: 2), maximumHeight: 900) == .place(220))
        #expect(state.resolve(snapshot(3, generation: 2, notices: 3), maximumHeight: 900) == .place(456))
        #expect(state.resolve(snapshot(generation: 3, complete: false), maximumHeight: 280) == .place(280))
        state.reset()
        #expect(state.currentHeight == 456)
    }
    @Test func resizeAnchorsCurrentTopIncludingAfterDragAndClampsOnlyWhenNeeded() throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 960), original = CGRect(x: 420, y: 300, width: 680, height: 456)
        let sparse = try #require(LauncherFrameGeometry.resized(original, height: 220, visibleFrame: screen))
        #expect(sparse.maxY == original.maxY && sparse.minX == original.minX && sparse.width == original.width)
        let dragged = sparse.offsetBy(dx: 100, dy: -100)
        let expanded = try #require(LauncherFrameGeometry.resized(dragged, height: 456, visibleFrame: screen))
        #expect(expanded.maxY == dragged.maxY && expanded.minX == dragged.minX)
        let high = CGRect(x: 10, y: 900, width: 680, height: 220)
        let clamped = try #require(LauncherFrameGeometry.resized(high, height: 456, visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 600)))
        #expect(clamped.maxY == 576 && clamped.minX == 10 && clamped.width == 680)
        let low = try #require(LauncherFrameGeometry.resized(CGRect(x: 10, y: -200, width: 680, height: 220), height: 456, visibleFrame: screen))
        #expect(low.minY == 24)
    }
    @Test func malformedRequestsDoNotChangeStateOrProduceInvalidFrames() {
        var state = LauncherLayoutState()
        for maximum in [CGFloat.nan, .infinity, 0, -1] { #expect(state.resolve(snapshot(1), maximumHeight: maximum) == .rejected) }
        #expect(state.resolve(snapshot(-1), maximumHeight: 900) == .rejected)
        #expect(state.resolve(snapshot(1, notices: 4), maximumHeight: 900) == .rejected)
        #expect(state.resolve(snapshot(complete: true), maximumHeight: 900) == .rejected)
        #expect(state.currentHeight == 456)
        #expect(LauncherFrameGeometry.resized(CGRect(x: 1, y: 1, width: 680, height: 456), height: .nan, visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 900)) == nil)
        #expect(LauncherFrameGeometry.resized(CGRect(x: 1, y: 1, width: 680, height: 456), height: 220, visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 48)) == nil)
    }
    @Test func newPresentationSeedsActualVisibleFrameRatherThanAssumingMaximumHeight() {
        var visible = LauncherLayoutState(initialHeight: 220)
        #expect(visible.resolve(snapshot(7), maximumHeight: 900) == .place(456))
        visible.reset(initialHeight: 600)
        #expect(visible.resolve(snapshot(7), maximumHeight: 900) == .place(456))
        visible.reset(initialHeight: .nan)
        #expect(visible.currentHeight == 456)
    }
    @Test func visibleReentryKeepsReservedNoticesAndSameHeightCanStillClampScreenPosition() throws {
        var state = LauncherLayoutState()
        #expect(state.resolve(snapshot(1, notices: 1), maximumHeight: 900) == .place(276))
        state.synchronizeActualHeight(276)
        #expect(state.resolve(snapshot(generation: 2, complete: false, notices: 1), maximumHeight: 900) == .place(276))
        #expect(state.resolve(snapshot(1, generation: 2), maximumHeight: 900) == .place(220))
        #expect(state.resolve(snapshot(1, generation: 2), maximumHeight: 600) == .place(220))
        let outside = CGRect(x: 100, y: 700, width: 680, height: 220), screen = CGRect(x: 0, y: 0, width: 1024, height: 600)
        let next = try #require(LauncherFrameGeometry.resized(outside, height: state.currentHeight, visibleFrame: screen))
        #expect(next.height == outside.height && next.maxY == 576)
        #expect(LauncherFrameGeometry.resized(next, height: state.currentHeight, visibleFrame: screen) == next)
    }
    @Test func noticeViewportFitsHeldAndLowFramesWithoutForcingFooterOutside() {
        #expect(LauncherLayoutMetrics.noticeViewportHeight(availableHeight: 220, slots: 3) == 74)
        #expect(LauncherLayoutMetrics.noticeViewportHeight(availableHeight: 388, slots: 3) == 168)
        #expect(LauncherLayoutMetrics.noticeViewportHeight(availableHeight: 100, slots: 3) == 0)
        #expect(LauncherLayoutMetrics.noticeViewportHeight(availableHeight: .nan, slots: 3) == 0)
    }
}
