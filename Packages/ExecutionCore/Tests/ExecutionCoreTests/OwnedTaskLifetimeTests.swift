import Testing
@testable import ExecutionCore

@Suite @MainActor struct OwnedTaskLifetimeTests {
    @Test func cancelledAndDiscardedWorkerIsStillDrainedBeforeQuit() async throws {
        let owner = OwnedTaskLifetime()
        var entered = false, workerEnded = false, lateEffects = 0
        var release: CheckedContinuation<Void, Never>?
        var slot = owner.start {
            entered = true
            await withCheckedContinuation { release = $0 }
            workerEnded = true
            if !Task.isCancelled { lateEffects += 1 }
        }
        while !entered { await Task.yield() }
        slot?.cancel(); slot = nil
        var waiting = false, drained = false
        let quit = Task { @MainActor in waiting = true; await owner.shutdownAndWait(); drained = true }
        while !waiting { await Task.yield() }
        #expect(!drained && !workerEnded && owner.activeCount == 1)
        try #require(release).resume()
        await quit.value
        #expect(drained && workerEnded && lateEffects == 0 && owner.activeCount == 0)
        #expect(owner.start { lateEffects += 1 } == nil)
    }
    @Test func cancelledBeforeStartNeverRunsTheBody() async throws {
        let owner = OwnedTaskLifetime(); var effects = 0
        let task = try #require(owner.start { effects += 1 })
        task.cancel(); await owner.shutdownAndWait()
        #expect(effects == 0 && owner.activeCount == 0)
    }
    @Test func completedWorkersAreReleasedWithoutGrowingHistory() async throws {
        let owner = OwnedTaskLifetime()
        for _ in 0..<20 { let task = try #require(owner.start {}); await task.value; #expect(owner.activeCount == 0) }
        await owner.shutdownAndWait()
    }
}
