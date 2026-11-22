import Foundation
import Testing
@testable import MacAdapters

@MainActor private final class SyntheticHotkeyRegistry: HotkeyRegistering {
    var receiver: (@Sendable (HotkeyEvent) -> Void)?
    var bindings: [UInt32: HotkeyBinding] = [:]
    var blocked: Set<HotkeyBinding> = []
    var attempts = 0
    var installationFailures = 0
    func install(receiver: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        if installationFailures > 0 { installationFailures -= 1; throw HotkeyRegistrationError(status: -50) }
        self.receiver = receiver
    }
    func register(id: UInt32, binding: HotkeyBinding) throws {
        attempts += 1
        guard !blocked.contains(binding), !bindings.values.contains(binding) else { throw HotkeyRegistrationError(status: -9878) }
        bindings[id] = binding
    }
    func unregister(id: UInt32) { bindings[id] = nil }
    func shutdown() { bindings = [:]; receiver = nil }
    func emit(_ id: UInt32, signature: UInt32 = HotkeyEvent.keyDockSignature) { receiver?(HotkeyEvent(signature: signature, id: id)) }
}

/// 只派发注册表的合成回调，不注册系统键、不创建或注入 NSEvent/CGEvent。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct HotkeyCenterTests {
    private let first = HotkeyBinding(keyCode: 0), second = HotkeyBinding(keyCode: 1)
    private func drain() async throws { try await Task.sleep(for: .milliseconds(10)) }

    @Test func aFailedReceiverInstallationCanRecoverWithoutReopening() throws {
        let registry = SyntheticHotkeyRegistry(); registry.installationFailures = 1
        let center = HotkeyCenter(registry: registry); defer { center.shutdown() }
        #expect(center.isUnavailable)
        try center.replace([.init(id: 1, binding: first) {}])
        #expect(!center.isUnavailable && center.activeIDs == [1])
    }

    @Test func rejectedWholePlanRestoresOldBindingWithFreshToken() async throws {
        let registry = SyntheticHotkeyRegistry()
        let actual = HotkeyCenter(registry: registry); defer { actual.shutdown() }
        var oldCalls = 0, newCalls = 0
        try actual.replace([.init(id: 1, binding: first) { oldCalls += 1 }])
        let stale = try #require(registry.bindings.keys.first)
        registry.blocked = [second]
        #expect(throws: HotkeyRegistrationError.self) {
            try actual.replace([.init(id: 1, binding: second) { newCalls += 1 }])
        }
        #expect(actual.activeIDs == [1] && actual.configuredIDs == [1])
        #expect(Set(registry.bindings.values) == [first])
        let restored = try #require(registry.bindings.keys.first)
        #expect(restored != stale)
        registry.emit(stale); registry.emit(restored)
        try await drain()
        #expect(oldCalls == 1 && newCalls == 0)
    }

    @Test func aFailedRestorationDisablesAllAndCanBeRetried() throws {
        let registry = SyntheticHotkeyRegistry(), center = HotkeyCenter(registry: registry)
        defer { center.shutdown() }
        try center.replace([.init(id: 1, binding: first) {}])
        registry.blocked = [first, second]
        do {
            try center.replace([.init(id: 1, binding: second) {}])
            Issue.record("Registration failure was not surfaced")
        } catch let error as HotkeyRegistrationError { #expect(error.restorationFailed) }
        #expect(center.isUnavailable && center.activeIDs.isEmpty && registry.bindings.isEmpty)
        #expect(center.configuredIDs == [1])
        registry.blocked = []
        try center.resume()
        #expect(!center.isUnavailable && center.activeIDs == [1])
        #expect(Set(registry.bindings.values) == [first])
    }

    @Test func resumeIsAllOrNothingAndRetryDoesNotSilentlyNoOp() throws {
        let registry = SyntheticHotkeyRegistry(), center = HotkeyCenter(registry: registry)
        defer { center.shutdown() }
        try center.replace([.init(id: 1, binding: first) {}, .init(id: 2, binding: second) {}])
        center.suspend(); registry.blocked = [second]
        #expect(throws: HotkeyRegistrationError.self) { try center.resume() }
        #expect(center.isUnavailable && center.activeIDs.isEmpty && registry.bindings.isEmpty)
        registry.blocked = []; try center.resume()
        #expect(center.activeIDs == [1, 2] && registry.bindings.count == 2)
    }

    @Test func delayedEventsCannotDispatchNewActionsAcrossReconfigureOrRecording() async throws {
        let registry = SyntheticHotkeyRegistry(), center = HotkeyCenter(registry: registry)
        defer { center.shutdown() }
        var oldCalls = 0, newCalls = 0
        try center.replace([.init(id: 1, binding: first) { oldCalls += 1 }])
        let stale = try #require(registry.bindings.keys.first)
        registry.emit(stale)
        try center.replace([.init(id: 1, binding: second) { newCalls += 1 }])
        try await drain()
        #expect(oldCalls == 0 && newCalls == 0)
        let beforeRecording = try #require(registry.bindings.keys.first)
        center.suspend(); registry.emit(beforeRecording); try center.resume()
        registry.emit(beforeRecording)
        let current = try #require(registry.bindings.keys.first)
        registry.emit(current, signature: 0x12345678)
        try await drain()
        #expect(newCalls == 0)
        registry.emit(current); try await drain()
        #expect(newCalls == 1)
    }

    @Test func duplicateBindingsAreRejectedBeforeDisturbingActiveKeysAndSwapsWork() throws {
        let registry = SyntheticHotkeyRegistry(), center = HotkeyCenter(registry: registry)
        defer { center.shutdown() }
        try center.replace([.init(id: 1, binding: first) {}, .init(id: 2, binding: second) {}])
        let before = registry.bindings, attempts = registry.attempts
        #expect(throws: HotkeyRegistrationError.self) {
            try center.replace([.init(id: 1, binding: first) {}, .init(id: 2, binding: first) {}])
        }
        #expect(registry.bindings == before && registry.attempts == attempts)
        try center.replace([.init(id: 1, binding: second) {}, .init(id: 2, binding: first) {}])
        #expect(center.activeIDs == [1, 2] && Set(registry.bindings.values) == [first, second])
    }

    @Test func recordingCannotAcceptAnUnverifiedSavedPlanAndShutdownNeverReactivates() async throws {
        let registry = SyntheticHotkeyRegistry(), center = HotkeyCenter(registry: registry)
        var calls = 0
        try center.replace([.init(id: 1, binding: first) { calls += 1 }])
        let stale = try #require(registry.bindings.keys.first)
        center.suspend()
        #expect(throws: HotkeyRegistrationError.self) { try center.replace([.init(id: 1, binding: second) {}]) }
        #expect(registry.bindings.isEmpty)
        try center.resume(); registry.emit(stale)
        let current = try #require(registry.bindings.keys.first)
        registry.emit(current); center.shutdown(); center.shutdown()
        try await drain()
        #expect(calls == 0 && center.activeIDs.isEmpty && center.configuredIDs.isEmpty)
        #expect(throws: HotkeyRegistrationError.self) { try center.resume() }
        #expect(throws: HotkeyRegistrationError.self) { try center.replace([.init(id: 1, binding: first) {}]) }
    }
}
