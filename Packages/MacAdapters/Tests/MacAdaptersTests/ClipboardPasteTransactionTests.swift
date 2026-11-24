import AppKit
import Testing
@testable import MacAdapters

@MainActor private final class SyntheticPasteDestination: ClipboardPasteDestination {
    var permitted = true
    var valid = true
    var front = true
    var activationAllowed = true
    var count = 10
    var validations = 0
    var staged: [String] = []
    var sent = 0
    var afterValidate: (() -> Void)?
    var validationWait: (@MainActor () async -> Void)?
    var afterStage: (() -> Void)?
    var isFrontmost: Bool { front }
    func validate() async -> Bool { validations += 1; await validationWait?(); let value = valid; afterValidate?(); return value }
    func activate() -> Bool { activationAllowed }
    func stageText(_ text: String) throws -> Int { staged.append(text); let value = count; afterStage?(); return value }
    func dispatchPaste(expectedChange: Int) throws {
        guard count == expectedChange else { throw ClipboardPasteError.clipboardChanged }
        sent += 1
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct ClipboardPasteTransactionTests {
    @Test func explicitPasteStagesOnceAndNeverReplaysAfterDispatch() async throws {
        let destination = SyntheticPasteDestination()
        var current = true
        try await ClipboardPasteTransaction.perform("Synthetic insert", destination: destination, isCurrent: { current })
        current = false
        #expect(destination.staged == ["Synthetic insert"] && destination.sent == 1)
    }
    @Test func MissingPermissionInvalidTargetOrCancellationNeverWrites() async {
        for mode in 0..<3 {
            let destination = SyntheticPasteDestination()
            destination.permitted = mode != 0; destination.valid = mode != 1
            do {
                try await ClipboardPasteTransaction.perform("Synthetic", destination: destination, isCurrent: { mode != 2 })
                Issue.record("An unavailable paste target was accepted")
            } catch {}
            #expect(destination.staged.isEmpty && destination.sent == 0)
        }
    }
    @Test func changedRangeWhileActivatingNeverStagesText() async {
        let destination = SyntheticPasteDestination(); destination.front = false
        destination.afterValidate = { if destination.validations == 2 { destination.valid = false } }
        do {
            try await ClipboardPasteTransaction.perform("Synthetic", destination: destination, isCurrent: { true })
            Issue.record("Changed target was accepted")
        } catch {}
        #expect(destination.staged.isEmpty && destination.sent == 0)
    }
    @Test func revocationAfterStagingStopsBeforeDispatch() async {
        let destination = SyntheticPasteDestination()
        destination.afterStage = { destination.permitted = false }
        do {
            try await ClipboardPasteTransaction.perform("Synthetic", destination: destination, isCurrent: { true })
            Issue.record("Revoked permission was accepted")
        } catch {}
        #expect(destination.staged.count == 1 && destination.sent == 0)
    }
    @Test func anotherClipboardWriterAfterStagingPreventsDispatch() async {
        let destination = SyntheticPasteDestination()
        destination.afterStage = { destination.count += 1 }
        do {
            try await ClipboardPasteTransaction.perform("Synthetic", destination: destination, isCurrent: { true })
            Issue.record("Another writer was accepted")
        } catch let error as ClipboardPasteError { #expect(error == .clipboardChanged) }
        catch { Issue.record("Unexpected error") }
        #expect(destination.sent == 0)
    }
    @Test func cancelledActivationCannotResumeAsALatePaste() async throws {
        let destination = SyntheticPasteDestination(); destination.front = false
        let task = Task { try await ClipboardPasteTransaction.perform("Synthetic", destination: destination, isCurrent: { true }) }
        while destination.validations == 0 { await Task.yield() }
        task.cancel(); destination.front = true
        do { try await task.value; Issue.record("Cancelled paste completed") } catch {}
        #expect(destination.staged.isEmpty && destination.sent == 0)
    }
    @Test func stagingUsesUniqueOwnershipAndTransientTypesOnAnIsolatedBoard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = ClipboardPasteboardStage(board: board), second = ClipboardPasteboardStage(board: board)
        let count = try first.write("Only synthetic text")
        #expect(first.owns(count))
        #expect(board.string(forType: .string) == "Only synthetic text")
        #expect(!ClipboardPolicy.allows(types: board.types?.map(\.rawValue) ?? [], source: nil, excluded: []))
        let other = try second.write("Second synthetic text")
        #expect(!first.owns(count) && second.owns(other))
        board.clearContents(); board.setString("External synthetic copy", forType: .string)
        #expect(!second.owns(board.changeCount))
    }
    @Test func thirdAppActivationPermanentlyRevokesEvenWhenOriginalTargetActivatesLate() async {
        let destination = SyntheticPasteDestination()
        let fence = ClipboardPasteActivationFence(ownPID: 100, targetPID: 200)
        fence.observeActivation(pid: 100); fence.observeActivation(pid: 200)
        #expect(!fence.revoked)
        fence.observeActivation(pid: 300); fence.observeActivation(pid: 200)
        do {
            try await ClipboardPasteTransaction.perform("Synthetic", destination: destination, isCurrent: { !fence.revoked })
            Issue.record("A revoked target accepted late activation")
        } catch {}
        #expect(destination.staged.isEmpty && destination.sent == 0)
    }
    @Test func revokedHandoffWhileAXValidationIsSuspendedCannotStageOrSend() async {
        let destination = SyntheticPasteDestination()
        let fence = ClipboardPasteActivationFence(ownPID: 100, targetPID: 200)
        var continuation: CheckedContinuation<Void, Never>?
        destination.validationWait = { await withCheckedContinuation { continuation = $0 } }
        let task = Task { try await ClipboardPasteTransaction.perform("Synthetic", destination: destination, isCurrent: { !fence.revoked }) }
        while continuation == nil { await Task.yield() }
        fence.observeActivation(pid: 300); fence.observeActivation(pid: 200)
        continuation?.resume()
        do { try await task.value; Issue.record("Stale pre-validation approval was reused") } catch {}
        #expect(destination.staged.isEmpty && destination.sent == 0)
    }
}
