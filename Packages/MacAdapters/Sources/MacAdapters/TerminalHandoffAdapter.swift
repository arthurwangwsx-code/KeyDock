import AppKit
import Foundation

/// 仅描述系统打开请求的回执，不把应用已打开当成命令执行成功。
public enum TerminalHandoffOutcome: Equatable, Sendable {
    case notSubmitted, acknowledged, rejected, unknown
}

/// 提交以后无法撤回 NSWorkspace 请求；有界等待结束不等于取消 Terminal 中的命令。
@MainActor public struct TerminalHandoffAdapter {
    public typealias Opener = @MainActor @Sendable (URL, @escaping @Sendable (Bool) -> Void) -> Void
    private let opener: Opener
    private let acknowledgementTimeout: Duration

    public init(acknowledgementTimeout: Duration = .seconds(3)) {
        self.init(acknowledgementTimeout: acknowledgementTimeout, opener: Self.systemOpen)
    }

    /// 注入合成回调即可测试超时/晚回执；测试不打开 Terminal、不执行脚本。
    public init(acknowledgementTimeout: Duration = .seconds(3), opener: @escaping Opener) {
        self.acknowledgementTimeout = min(.seconds(5), max(.milliseconds(1), acknowledgementTimeout))
        self.opener = opener
    }

    public func open(
        file: URL,
        beforeSubmission: @MainActor () -> Bool = { true },
        onSubmission: @MainActor () -> Void = {}
    ) async -> TerminalHandoffOutcome {
        guard !Task.isCancelled, beforeSubmission() else { return .notSubmitted }
        return await withCheckedContinuation { continuation in
            let gate = TerminalAcknowledgementGate(continuation)
            // 从提交片段起计绝对期限；计时不再等待主线程空闲后才开始。
            let expiresAt = ContinuousClock.now.advanced(by: acknowledgementTimeout)
            let deadline = Task.detached {
                do { try await Task.sleep(until: expiresAt, clock: .continuous) }
                catch { return }
                gate.resolve(.unknown)
            }
            gate.installDeadline(deadline)
            // 同一个主线程片段完成状态切换与 OS 提交，中间没有 await。
            onSubmission()
            opener(file) { accepted in gate.resolve(accepted ? .acknowledged : .rejected) }
        }
    }

    private static func systemOpen(file: URL, reply: @escaping @Sendable (Bool) -> Void) {
        let workspace = NSWorkspace.shared
        guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            reply(false); return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        workspace.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
            reply(error == nil)
        }
    }
}

/// NSWorkspace 回调不参与结构化等待；锁只保护单次续体和计时任务，不访问 UI。
private final class TerminalAcknowledgementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TerminalHandoffOutcome, Never>?
    private var deadline: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<TerminalHandoffOutcome, Never>) {
        self.continuation = continuation
    }

    func installDeadline(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadySettled = continuation == nil
        if !alreadySettled { deadline = task }
        lock.unlock()
        if alreadySettled { task.cancel() }
    }

    func resolve(_ outcome: TerminalHandoffOutcome) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let deadline = self.deadline; self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        // 超时后的成功、失败或重复回调都不再恢复续体或改变宿主终态。
        continuation.resume(returning: outcome)
    }
}
