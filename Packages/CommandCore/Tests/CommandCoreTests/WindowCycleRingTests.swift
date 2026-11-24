import Testing
import CommandCore

struct WindowCycleRingTests {
    @Test func nextTraversesEveryWindowDespiteRaiseReordering() throws {
        var ring = WindowCycleRing()
        var focus = "A"
        for (snapshot, expected) in [(["A", "B", "C"], "B"), (["B", "A", "C"], "C"), (["C", "B", "A"], "A")] {
            let move = try #require(({ ring.prepare(direction: .next, windowIDs: snapshot, focusedID: focus) })())
            #expect(move.sourceID == focus && move.targetID == expected)
            #expect(ring.focusedID == focus)
            #expect(({ ring.commit(move, confirmedFocusedID: expected) })())
            focus = expected
        }
        #expect(ring.windowIDs == ["A", "B", "C"])
    }

    @Test func previousTraversesInReverseAndWraps() throws {
        var ring = WindowCycleRing(), focus = "A"
        for (snapshot, expected) in [(["A", "B", "C"], "C"), (["C", "A", "B"], "B"), (["B", "C", "A"], "A")] {
            let move = try #require(({ ring.prepare(direction: .previous, windowIDs: snapshot, focusedID: focus) })())
            #expect(move.targetID == expected)
            #expect(({ ring.commit(move, confirmedFocusedID: expected) })())
            focus = expected
        }
    }

    @Test func failedReadbackDoesNotAdvanceOrPermitLateSuccess() throws {
        var ring = WindowCycleRing()
        let move = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        #expect(!({ ring.commit(move, confirmedFocusedID: nil) })())
        #expect(ring.focusedID == "A")
        #expect(!({ ring.commit(move, confirmedFocusedID: "B") })())
        let retry = try #require(({ ring.prepare(direction: .next, windowIDs: ["C", "B", "A"], focusedID: "A") })())
        #expect(retry.targetID == "B")
    }

    @Test func wrongReadbackFailsThenFreshExternalFocusRebases() throws {
        var ring = WindowCycleRing()
        let move = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        #expect(!({ ring.commit(move, confirmedFocusedID: "C") })())
        #expect(ring.focusedID == "A")
        let next = try #require(({ ring.prepare(direction: .next, windowIDs: ["C", "A", "B"], focusedID: "C") })())
        #expect(next.sourceID == "C" && next.targetID == "A")
    }

    @Test func externalFocusAfterSuccessResetsBaseline() throws {
        var ring = WindowCycleRing()
        let move = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        #expect(({ ring.commit(move, confirmedFocusedID: "B") })())
        let generation = ring.generation
        ring.synchronize(windowIDs: ["C", "B", "A"], focusedID: "C")
        #expect(ring.generation != generation)
        #expect(try #require(({ ring.prepare(direction: .next, windowIDs: ["C", "A", "B"], focusedID: "C") })()).targetID == "A")
    }

    @Test func oldNonceCannotCommitOrCancelNewPendingTransition() throws {
        var ring = WindowCycleRing()
        let old = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        let current = try #require(({ ring.prepare(direction: .previous, windowIDs: ["C", "A", "B"], focusedID: "A") })())
        #expect(current.generation == old.generation && current.nonce != old.nonce)
        #expect(!ring.isCurrent(old) && ring.isCurrent(current))
        #expect(!({ ring.commit(old, confirmedFocusedID: "B") })())
        #expect(!({ ring.cancel(old) })())
        #expect(({ ring.commit(current, confirmedFocusedID: "C") })())
        #expect(!ring.isCurrent(current))
        #expect(!({ ring.commit(current, confirmedFocusedID: "C") })())
    }

    @Test func externalFocusAwayAndBackStillRejectsOldGeneration() throws {
        var ring = WindowCycleRing()
        let old = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        ring.synchronize(windowIDs: ["C", "A", "B"], focusedID: "C")
        ring.synchronize(windowIDs: ["A", "C", "B"], focusedID: "A")
        #expect(ring.generation != old.generation)
        #expect(!({ ring.commit(old, confirmedFocusedID: "B") })())
        #expect(ring.focusedID == "A")
    }

    @Test func closesDisappearAndNewWindowsAppendWithoutResortingSurvivors() throws {
        var ring = WindowCycleRing()
        ring.synchronize(windowIDs: ["A", "B", "C"], focusedID: "B")
        ring.synchronize(windowIDs: ["D", "C", "A", "E"], focusedID: "A")
        #expect(ring.windowIDs == ["A", "C", "D", "E"])
        #expect(try #require(({ ring.prepare(direction: .next, windowIDs: ["E", "D", "C", "A"], focusedID: "A") })()).targetID == "C")
    }

    @Test func membershipChangeRejectsOldReceiptEvenWhenSourceAndTargetSurvive() throws {
        var ring = WindowCycleRing()
        let old = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        ring.synchronize(windowIDs: ["B", "D", "A"], focusedID: "A")
        #expect(ring.windowIDs == ["A", "B", "D"])
        #expect(!({ ring.commit(old, confirmedFocusedID: "B") })())
        #expect(ring.focusedID == "A")
    }

    @Test func closedTargetCannotBeConfirmedByLateReadback() throws {
        var ring = WindowCycleRing()
        let old = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        ring.synchronize(windowIDs: ["C", "A"], focusedID: "A")
        #expect(!({ ring.commit(old, confirmedFocusedID: "B") })())
        #expect(try #require(({ ring.prepare(direction: .next, windowIDs: ["C", "A"], focusedID: "A") })()).targetID == "C")
    }

    @Test func duplicatesAndEmptyIDsDoNotCreateExtraStops() throws {
        var ring = WindowCycleRing()
        ring.synchronize(windowIDs: ["", "A", "A", "B", "C", "B"], focusedID: "A")
        ring.synchronize(windowIDs: ["B", "D", "B", "C", "A", "D", ""], focusedID: "A")
        #expect(ring.windowIDs == ["A", "B", "C", "D"])
        #expect(try #require(({ ring.prepare(direction: .previous, windowIDs: ["A", "D", "C", "B"], focusedID: "A") })()).targetID == "D")
    }

    @Test func capacityPreservesTrackedWindowsEvenBeyondIncomingPrefix() throws {
        var ring = WindowCycleRing()
        let ids = (0..<160).map { "window-\($0)" }
        ring.synchronize(windowIDs: ids, focusedID: ids[0])
        let initial = Array(ids.prefix(128)), generation = ring.generation
        ring.synchronize(windowIDs: Array(ids.reversed()), focusedID: ids[0])
        #expect(ring.windowIDs == initial && ring.generation == generation)
        #expect(ring.windowIDs.count == WindowCycleRing.maximumWindowCount)
        #expect(try #require(({ ring.prepare(direction: .next, windowIDs: Array(ids.reversed()), focusedID: ids[0]) })()).targetID == ids[1])
    }

    @Test func overCapacityStillAdmitsVerifiedFocusedWindow() throws {
        var ring = WindowCycleRing()
        let ids = (0..<160).map { "window-\($0)" }
        ring.synchronize(windowIDs: ids, focusedID: ids[159])
        #expect(ring.windowIDs == Array(ids.prefix(127)) + [ids[159]])
        let move = try #require(({ ring.prepare(direction: .next, windowIDs: Array(ids.reversed()), focusedID: ids[159]) })())
        #expect(move.sourceID == ids[159] && move.targetID == ids[0])
    }

    @Test func noConfirmedFocusOrOnlyOneWindowDoesNotGuessTarget() {
        var ring = WindowCycleRing()
        #expect(({ ring.prepare(direction: .next, windowIDs: [], focusedID: nil) })() == nil)
        #expect(({ ring.prepare(direction: .next, windowIDs: ["A", "A", ""], focusedID: "A") })() == nil)
        #expect(({ ring.prepare(direction: .next, windowIDs: ["A", "B"], focusedID: nil) })() == nil)
        #expect(({ ring.prepare(direction: .previous, windowIDs: ["A", "B"], focusedID: "missing") })() == nil)
    }

    @Test func cancellationKeepsBaselineAndCannotLaterCommit() throws {
        var ring = WindowCycleRing()
        let move = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B", "C"], focusedID: "A") })())
        #expect(({ ring.cancel(move) })())
        #expect(!({ ring.cancel(move) })() && !({ ring.commit(move, confirmedFocusedID: "B") })())
        #expect(ring.focusedID == "A")
        #expect(try #require(({ ring.prepare(direction: .next, windowIDs: ["B", "A", "C"], focusedID: "A") })()).targetID == "B")
    }

    @Test func resetRejectsOldReceiptEvenAfterSameIDsReappear() throws {
        var ring = WindowCycleRing()
        let old = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B"], focusedID: "A") })())
        ring.reset()
        let current = try #require(({ ring.prepare(direction: .next, windowIDs: ["A", "B"], focusedID: "A") })())
        #expect(current.generation != old.generation)
        #expect(!({ ring.commit(old, confirmedFocusedID: "B") })())
        #expect(({ ring.commit(current, confirmedFocusedID: "B") })())
    }
}
