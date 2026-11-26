import Foundation
import Combine
import ExecutionCore
import AICore

enum AttemptReceiptStore: Sendable, Equatable { case cli, ai }
struct AttemptOrigin: Sendable, Equatable {
    let store: AttemptReceiptStore
    let invocationID: UUID
}
enum AttemptPreparationError: Error { case unavailable, changed, busy, needsMCPConnection, invalidInput, scopeTooLarge, admissionFailed }

struct AttemptReviewStamp: Equatable, Sendable {
    let history: UInt64
    let configuration: UUID
    let contribution: UUID
    let mcp: UUID
    let catalogs: UUID
}
struct AttemptMCPScope: Codable, Equatable, Sendable {
    let serverID: UUID
    let configurationRevision: UUID
    let selectedNames: [String]
    let catalogRevision: String
    let contractDigest: String
}
struct AttemptScopeLine: Identifiable, Sendable {
    let id = UUID()
    enum Kind: String, Sendable { case command, service, tools, budget, steps, turns, calls, builtIn, directory, environment }
    let kind: Kind
    let value: String
    var title: String {
        switch kind {
        case .command: L("Saved command")
        case .service: L("AI service and model")
        case .tools: L("MCP tool")
        case .budget: L("Timeout")
        case .steps: L("Steps")
        case .turns: L("Maximum turns")
        case .calls: L("Maximum tool calls")
        case .builtIn: L("Built-in tools")
        case .directory: L("Working directory")
        case .environment: L("Environment overrides")
        }
    }
}
struct AttemptPreparationReview: Identifiable, Sendable {
    let id = UUID()
    let origin: AttemptOrigin
    let recovery: RunRecoveryCheck
    let definition: RunDefinitionReference
    let stamp: AttemptReviewStamp
    let dependencyFingerprint: String
    let mcpScopes: [AttemptMCPScope]
    let title: String
    let lines: [AttemptScopeLine]
    let scopePreview: String
    let allowsInput: Bool
    let requiresInput: Bool
    var definitionChanged: Bool { recovery.receipt.runAttempt?.definition != definition }
    var requiresEffectAcknowledgment: Bool {
        recovery.receipt.state == .interrupted || recovery.receipt.message.hasPrefix("terminal.")
    }
    var previousState: String {
        if recovery.receipt.message == "ai.paused" { return TaskStatus.paused.title }
        if recovery.receipt.message == "terminal.handedOff" { return TaskStatus.handedOff.title }
        return switch recovery.receipt.state {
        case .queued: TaskStatus.queued.title
        case .running: TaskStatus.running.title
        case .succeeded: TaskStatus.completed.title
        case .failed: TaskStatus.failed.title
        case .cancelled: TaskStatus.cancelled.title
        case .timedOut: TaskStatus.timedOut.title
        case .interrupted: TaskStatus.interrupted.title
        }
    }
}

/// worker持有本次begin的准确actor与出生身份，不在清理时按ID重新猜测所有权。
struct InvocationWorkerOwnership: Sendable {
    let store: InvocationStore
    let begun: InvocationBeginReceipt
    var id: UUID { begun.receipt.id }
    func finish(_ result: ProcessResult, runTokenBudget: RunTokenBudgetSnapshot? = nil) async throws {
        try await store.finish(id: id, result: result, runTokenBudget: runTokenBudget, expectedRunStamp: begun.runStamp)
    }
    func release() async { await store.releaseProtection(for: id, expectedRunStamp: begun.runStamp) }
    func abandon() async { await store.abandonUndispatched(id, expectedRunStamp: begun.runStamp) }
}

/// 仅存于本进程的提交门票。审阅围栏止于首次派发，之后沿用既有运行生命周期／撤权合同。
@MainActor final class AttemptExecutionContext {
    let id = UUID()
    let review: AttemptPreparationReview
    let input: String
    private let presentationIsCurrent: @MainActor () -> Bool
    private var completion: ((Result<InvocationWorkerOwnership, Error>) -> Void)?
    private(set) var admitted = false
    private(set) var dispatched = false
    private var rejected = false
    init(review: AttemptPreparationReview, input: String, isCurrent: @escaping @MainActor () -> Bool,
         completion: @escaping (Result<InvocationWorkerOwnership, Error>) -> Void) {
        self.review = review; self.input = input; presentationIsCurrent = isCurrent; self.completion = completion
    }
    func validate(in store: WorkbenchModel) throws {
        guard !rejected, !store.isShuttingDown, !store.cancelledTaskIDs.contains(id), !Task.isCancelled else { throw CancellationError() }
        guard dispatched || (store.isCurrentAttemptReview(review) && (admitted || presentationIsCurrent())) else { throw AttemptPreparationError.changed }
    }
    func accept(_ owner: InvocationWorkerOwnership, in store: WorkbenchModel) throws {
        try validate(in: store)
        guard owner.id == id, owner.begun.runStamp != nil, !admitted else { throw AttemptPreparationError.admissionFailed }
        admitted = true
        let callback = completion; completion = nil; callback?(.success(owner))
    }
    func willDispatch(in store: WorkbenchModel) throws { try validate(in: store); dispatched = true }
    func fail(_ error: Error) {
        guard !admitted else { return }
        rejected = true; let callback = completion; completion = nil; callback?(.failure(error))
    }
}

/// 独立输入和呈现身份；刷新不丢文本，迟到读取、旧确认与旧dismiss都不能接纳新工作。
@MainActor final class AttemptPreparationPresentation: ObservableObject, Identifiable {
    enum Phase: Equatable { case idle, reading(UUID), ready, needsReview, unavailable, submitting(UUID), admitted(UUID), closed }
    let id = UUID()
    let origin: AttemptOrigin
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var review: AttemptPreparationReview?
    @Published private(set) var input = ""
    @Published private(set) var inputRejected = false
    @Published var effectsChecked = false
    @Published private(set) var notice: LocalizedNotice = .none
    private(set) var appeared = false
    private(set) var admittedTaskID: UUID?
    private(set) var inputRevision = UUID()
    let materialInput = AttemptMaterialInput()
    private var operation: Task<Void, Never>?
    var isSubmitting: Bool { if case .submitting = phase { true } else { false } }
    var isReading: Bool { if case .reading = phase { true } else { false } }
    var shouldDismiss: Bool { if case .closed = phase { true } else if case .admitted = phase { true } else { false } }
    init(_ origin: AttemptOrigin) { self.origin = origin }
    func didAppear() { if !shouldDismiss { appeared = true } }
    func editInput(_ value: String) {
        guard !isSubmitting, !shouldDismiss else { return }
        if !input.utf8.elementsEqual(value.utf8) { inputRevision = UUID(); materialInput.invalidate() }
        guard value.utf8.count <= TaskTextLimits.inputBytes else {
            inputRejected = true; notice = noticeKey("Input is too long. Split it into smaller parts; nothing was sent."); return
        }
        if !input.utf8.elementsEqual(value.utf8) { input = value }
        inputRejected = false
        if phase == .ready { notice = .none }
    }
    func canSubmit(in store: WorkbenchModel) -> Bool {
        guard phase == .ready, !inputRejected, let review, store.isCurrentAttemptReview(review),
              !review.requiresInput || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !review.requiresEffectAcknowledgment || effectsChecked else { return false }
        return true
    }
    @discardableResult func refresh(in store: WorkbenchModel) -> Task<Void, Never>? {
        guard !isSubmitting, !shouldDismiss else { return nil }
        materialInput.invalidate(); operation?.cancel(); let token = UUID(); phase = .reading(token); notice = .none; effectsChecked = false
        operation = Task { [weak self] in
            do {
                guard let self else { return }
                let value = try await store.reviewAttempt(origin)
                guard phase == .reading(token), !Task.isCancelled else { return }
                guard store.isCurrentAttemptReview(value) else { throw AttemptPreparationError.changed }
                review = value; phase = .ready; operation = nil
            } catch { self?.report(error, while: .reading(token)) }
        }
        return operation
    }
    @discardableResult func confirm(_ reviewID: UUID, in store: WorkbenchModel) -> Task<Void, Never>? {
        guard canSubmit(in: store), let review, review.id == reviewID else { return nil }
        materialInput.invalidate()
        let nonce = UUID(), revision = inputRevision, text = input
        phase = .submitting(nonce); notice = .none
        operation = Task { [weak self] in
            do {
                let owner = try await store.admitAttempt(review, input: text, isCurrent: { [weak self] in
                    self?.phase == .submitting(nonce) && self?.review?.id == reviewID && self?.inputRevision == revision
                }, didAdmit: { [weak self] id in
                    guard let self, phase == .submitting(nonce) else { return }
                    admittedTaskID = id; phase = .admitted(id)
                })
                guard let self, admittedTaskID == owner.id else { return }
                operation = nil
            } catch { self?.report(error, while: .submitting(nonce)) }
        }
        return operation
    }
    func validateReview(in store: WorkbenchModel) {
        guard phase == .ready, let review, !store.isCurrentAttemptReview(review) else { return }
        materialInput.invalidate()
        phase = .needsReview; notice = noticeKey("This attempt or its settings changed. Review again before starting. Your input was kept.")
    }
    func sourceRemoved() {
        guard !shouldDismiss, !isSubmitting else { return }
        materialInput.invalidate()
        operation?.cancel(); operation = nil; phase = .unavailable
        notice = noticeKey("This attempt or its saved definition is no longer available. History remains read-only.")
    }
    private func report(_ error: Error, while expected: Phase) {
        guard phase == expected else { return }; operation = nil
        switch error {
        case AttemptPreparationError.unavailable, InvocationStoreError.recoveryUnavailable:
            phase = .unavailable; notice = noticeKey("This attempt or its saved definition is no longer available. History remains read-only.")
        case AttemptPreparationError.needsMCPConnection:
            phase = .needsReview; notice = noticeKey("Connect or refresh the selected MCP sources first, then review this attempt again. Nothing was sent.")
        case AIProviderError.invalidConfiguration:
            phase = .needsReview; notice = noticeKey("Set a compatible AI endpoint and model in Settings, then review again.")
        case AttemptPreparationError.busy, InvocationStoreError.activeRecovery:
            phase = .needsReview; notice = noticeKey("The previous worker is still finishing. Wait, then review again.")
        case AttemptPreparationError.scopeTooLarge:
            phase = .needsReview; notice = noticeKey("This saved definition is too large for an attempt review. Edit it before trying again.")
        case AttemptPreparationError.changed, InvocationStoreError.staleRecovery, is CancellationError:
            phase = .needsReview; notice = noticeKey("This attempt or its settings changed. Review again before starting. Your input was kept.")
        default:
            phase = .needsReview; notice = noticeKey("The new attempt could not be admitted. Your input was kept; review settings and try again.")
        }
    }
    func invalidate() { materialInput.invalidate(); phase = .closed; operation?.cancel(); operation = nil }
}
