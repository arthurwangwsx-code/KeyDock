import Foundation
import Combine
import SwiftUI
import KeyDockUI

/// 填入只复制已校验原输入；不持有提交/恢复权限，也不以结果或成功步骤文本兜底。
@MainActor final class AttemptMaterialInput: ObservableObject {
    private struct Ticket {
        let presentationID: UUID, reviewID: UUID, inputRevision: UUID, requestID: UUID, generation: UUID
        let handle: TaskMaterialHandle
    }
    @Published private(set) var isLoading = false
    @Published private(set) var replacementReady = false
    @Published private(set) var buffer: TaskMaterialBuffer?
    @Published private(set) var notice: LocalizedNotice = .none
    private var ticket: Ticket?
    private var requestID = UUID()
    private weak var owner: WorkbenchModel?
    private var operation: Task<Void, Never>?

    func availableHandle(_ presentation: AttemptPreparationPresentation, in store: WorkbenchModel) -> TaskMaterialHandle? {
        guard presentation.phase == .ready, let review = presentation.review, review.allowsInput,
              let birth = review.recovery.receipt.runAttempt?.recordIdentity else { return nil }
        let key = TaskMaterialKey(receiptStore: presentation.origin.store == .cli ? .cli : .ai,
            invocationID: presentation.origin.invocationID, receiptRecordIdentity: birth)
        guard let handle = store.taskMaterialHandles[key], handle.header.fields.contains(.input) else { return nil }
        return handle
    }
    @discardableResult func load(into presentation: AttemptPreparationPresentation, in store: WorkbenchModel) -> Task<Void, Never>? {
        guard !isLoading, let handle = availableHandle(presentation, in: store), let review = presentation.review,
              store.isCurrentAttemptReview(review) else { return nil }
        invalidate(); owner = store
        let token = Ticket(presentationID: presentation.id, reviewID: review.id, inputRevision: presentation.inputRevision,
            requestID: requestID, generation: store.taskMaterialFence.current.generation, handle: handle)
        ticket = token; isLoading = true
        operation = Task { [weak self, weak presentation] in
            var acquired: TaskMaterialBuffer?
            do {
                acquired = try await store.readTaskMaterial(handle)
                guard let self, let presentation, accepts(token, presentation, store), let acquired else {
                    if let acquired { store.releaseTaskMaterialBuffer(acquired.id) }; return
                }
                try acquired.keepOnlyInput()
                buffer = acquired
                if presentation.input.isEmpty { try await apply(token, presentation, store) }
                else { replacementReady = true; isLoading = false; operation = nil }
            } catch {
                if let acquired { store.releaseTaskMaterialBuffer(acquired.id) }
                guard let self, self.requestID == token.requestID else { return }
                buffer = nil; isLoading = false; replacementReady = false; operation = nil
                notice = store.taskMaterialErrorNotice(error)
            }
        }
        return operation
    }
    @discardableResult func replace(into presentation: AttemptPreparationPresentation, in store: WorkbenchModel) -> Task<Void, Never>? {
        guard replacementReady, !isLoading, let token = ticket, accepts(token, presentation, store) else { return nil }
        isLoading = true; replacementReady = false
        operation = Task { [weak self, weak presentation] in
            do {
                guard let self, let presentation else { return }
                try await apply(token, presentation, store)
            } catch {
                guard let self, requestID == token.requestID else { return }
                invalidate(); notice = store.taskMaterialErrorNotice(error)
            }
        }
        return operation
    }
    private func apply(_ token: Ticket, _ presentation: AttemptPreparationPresentation, _ store: WorkbenchModel) async throws {
        guard accepts(token, presentation, store), let text = buffer?.material?.input else { throw TaskMaterialError.staleCheck }
        let current = try await store.taskMaterialStore.inspect(token.handle.key)
        guard let current, current.version == token.handle.version, current.fileIdentity == token.handle.fileIdentity,
              current.headerSHA256 == token.handle.headerSHA256 else { throw TaskMaterialError.changed }
        let hasOwner = try await store.materialOwnerExists(token.handle.key)
        guard hasOwner, accepts(token, presentation, store), !Task.isCancelled else { throw TaskMaterialError.staleCheck }
        invalidate()
        presentation.editInput(text)
        notice = noticeKey("Retained input filled. Review the current scope before starting a new attempt.")
    }
    private func accepts(_ token: Ticket, _ presentation: AttemptPreparationPresentation, _ store: WorkbenchModel) -> Bool {
        requestID == token.requestID && presentation.id == token.presentationID && presentation.phase == .ready &&
        presentation.review?.id == token.reviewID && presentation.inputRevision == token.inputRevision &&
        store.taskMaterialFence.current.generation == token.generation && !store.isShuttingDown && !store.isClearingHistory &&
        !store.taskMaterialClearing && presentation.review.map { store.isCurrentAttemptReview($0) } == true
    }
    func invalidate() {
        requestID = UUID(); ticket = nil; operation?.cancel(); operation = nil; isLoading = false; replacementReady = false
        if let buffer { owner?.releaseTaskMaterialBuffer(buffer.id) }
        buffer = nil; notice = .none
    }
}

struct AttemptMaterialInputView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var presentation: AttemptPreparationPresentation
    @ObservedObject var state: AttemptMaterialInput
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L("Use retained input")) { store.performUserInputAction { state.load(into: presentation, in: store) } }
                .disabled(state.isLoading || state.availableHandle(presentation, in: store) == nil)
            if state.isLoading { ProgressView(L("Reading retained input…")).controlSize(.small) }
            if state.replacementReady, let buffer = state.buffer { AttemptMaterialReplacementView(store: store, presentation: presentation, state: state, buffer: buffer) }
            if !state.notice.rendered().isEmpty { Text(state.notice.rendered()).font(.caption).foregroundStyle(.secondary) }
        }.onChange(of: store.taskMaterialGeneration) { _, _ in state.invalidate() }
    }
}
private struct AttemptMaterialReplacementView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var presentation: AttemptPreparationPresentation
    @ObservedObject var state: AttemptMaterialInput
    @ObservedObject var buffer: TaskMaterialBuffer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Your current input is kept until you explicitly replace it.")).font(.caption).foregroundStyle(.secondary)
            if let input = buffer.material?.input { ReadOnlyTextPreview(text: input, accessibilityLabel: L("Retained input preview"), monospaced: true).frame(height: 120).modifier(KDReadingSurface()) }
            HStack {
                Button(L("Replace current input")) { store.performUserInputAction { state.replace(into: presentation, in: store) } }
                Button(L("Keep current input")) { state.invalidate() }
            }
        }
    }
}
