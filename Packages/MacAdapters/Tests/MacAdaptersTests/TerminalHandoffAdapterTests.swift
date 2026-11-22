import Foundation
import Testing
@testable import MacAdapters

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct TerminalHandoffAdapterTests {
    private let file = URL(fileURLWithPath: "/tmp/keydock-synthetic-not-executed.command")

    @Test func cancelledBeforeSubmissionNeverCallsTheOpener() async {
        var opens = 0, submissions = 0
        let adapter = TerminalHandoffAdapter { _, _ in opens += 1 }
        let outcome = await adapter.open(file: file, beforeSubmission: { false }, onSubmission: { submissions += 1 })
        #expect(outcome == .notSubmitted && opens == 0 && submissions == 0)
    }

    @Test func immediateAcknowledgementSettlesOnceDespiteDuplicateCallbacks() async throws {
        let adapter = TerminalHandoffAdapter(acknowledgementTimeout: .milliseconds(20)) { _, reply in
            reply(true); reply(false)
        }
        #expect(await adapter.open(file: file) == .acknowledged)
        // 被取消的定时器也不能再恢复同一个续体。
        try await Task.sleep(for: .milliseconds(40))
    }

    @Test func anExplicitRejectionDoesNotBecomeAcknowledgementOrTimeout() async {
        let adapter = TerminalHandoffAdapter { _, reply in reply(false) }
        #expect(await adapter.open(file: file) == .rejected)
    }

    @Test func aSilentOpenerReturnsUnknownWithinTheBudget() async {
        let adapter = TerminalHandoffAdapter(acknowledgementTimeout: .milliseconds(20)) { _, _ in }
        let started = ContinuousClock.now
        #expect(await adapter.open(file: file) == .unknown)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test func cancellationAfterSubmissionDoesNotPretendToRecallTheOSRequest() async {
        var reply: (@Sendable (Bool) -> Void)?
        let adapter = TerminalHandoffAdapter(acknowledgementTimeout: .milliseconds(30)) { _, completion in reply = completion }
        let pending = Task { await adapter.open(file: file) }
        while reply == nil { await Task.yield() }
        pending.cancel()
        #expect(await pending.value == .unknown)
        // 系统在超时后才确认、甚至重复回调，都不能改写 unknown 或双重恢复。
        reply?(true); reply?(false)
        await Task.yield()
    }
}
