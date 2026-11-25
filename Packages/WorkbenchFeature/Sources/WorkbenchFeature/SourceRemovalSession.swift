import Foundation
import Combine
import AutomationCore

@MainActor final class SourceRemovalPresentation: ObservableObject, Identifiable {
    let id = UUID()
    let target: SavedSourceTarget
    @Published private(set) var review: SourceRemovalReview?
    @Published private(set) var notice: LocalizedNotice = .none
    @Published private(set) var detail: LocalizedNotice = .none
    @Published private(set) var isBusy = false
    @Published private(set) var isConfirming = false
    @Published private(set) var invalidated = false
    @Published private(set) var removed = false
    private(set) var appeared = false
    private var reviewIsCurrent = false
    private var operationID: UUID?
    private var task: Task<Void, Never>?
    var canConfirm: Bool { !invalidated && !removed && !isBusy && reviewIsCurrent && review?.dependencies.isEmpty == true }
    init(_ target: SavedSourceTarget) { self.target = target }
    func didAppear() { if !invalidated { appeared = true } }

    @discardableResult func refresh(in store: WorkbenchModel, scheduleReader: (@Sendable () async -> ScheduleDefinitionExportSnapshot)? = nil) -> Task<Void, Never>? {
        guard !invalidated, !removed, !isBusy else { return nil }
        let operation = UUID(); operationID = operation; isBusy = true; reviewIsCurrent = false; notice = .none; detail = .none
        let target = target
        task = Task { [weak self] in
            do {
                guard self?.accepts(operation) == true else { return }
                let result = try await store.reviewSourceRemoval(target, scheduleReader: scheduleReader)
                guard let self, self.accepts(operation) else { return }
                self.review = result; self.reviewIsCurrent = true; self.finishOperation()
            } catch {
                guard let self, self.accepts(operation) else { return }
                self.report(error); self.finishOperation()
            }
        }
        return task
    }
    @discardableResult func confirm(_ reviewID: UUID, in store: WorkbenchModel, scheduleReader: (@Sendable () async -> ScheduleDefinitionExportSnapshot)? = nil) -> Task<Void, Never>? {
        guard canConfirm, let review, review.id == reviewID else { return nil }
        let operation = UUID(); operationID = operation; isBusy = true; isConfirming = true; notice = .none; detail = .none
        task = Task { [weak self] in
            do {
                try await store.removeSource(review, isCurrent: { [weak self] in self?.accepts(operation) == true && self?.review?.id == review.id }, scheduleReader: scheduleReader)
                guard let self, self.accepts(operation) else { return }
                self.finishOperation(); self.removed = true
            } catch {
                guard let self, self.accepts(operation) else { return }
                self.report(error); self.finishOperation()
            }
        }
        return task
    }
    private func accepts(_ operation: UUID) -> Bool { !invalidated && !removed && operationID == operation }
    private func finishOperation() { operationID = nil; task = nil; isBusy = false; isConfirming = false }
    private func report(_ error: Error) {
        switch error {
        case SourceRemovalError.unavailable:
            reviewIsCurrent = false; notice = noticeKey("This saved source is no longer available. Keep any editor draft and choose a current source.")
        case SourceRemovalError.changed:
            reviewIsCurrent = false; notice = noticeKey("This source or its references changed. Review again before removing it.")
        case SourceRemovalError.inUse:
            reviewIsCurrent = false; notice = noticeKey("This item is still in use. Remove its references, then review again.")
        case SourceRemovalError.busy:
            notice = noticeKey("Another settings change is finishing. Wait, then try again.")
        case SourceRemovalError.persistence(let value):
            notice = noticeKey("The source could not be removed. The review is kept; check the save error before retrying."); detail = value
        case SourceRemovalError.mcpPersistencePaused(let value):
            notice = noticeKey("The MCP source could not be removed. Its definition is kept and connections are paused for this session. Saved enablement may return after restarting."); detail = value
        case is CancellationError: break
        default: reviewIsCurrent = false; notice = noticeKey("The source review could not be prepared. No source was removed.")
        }
    }
    func invalidate() {
        invalidated = true; operationID = nil; task?.cancel(); task = nil
        reviewIsCurrent = false; isBusy = false; isConfirming = false
    }
}

extension SettingsSession {
    func prepareSourceRemoval(_ target: SavedSourceTarget, in store: WorkbenchModel) {
        guard canBeginSavedItemEditor else { return }
        let presentation = SourceRemovalPresentation(target); sourceRemoval = presentation; presentation.refresh(in: store)
    }
    func sourceRemovalDidAppear(_ id: UUID) { if sourceRemoval?.id == id { sourceRemoval?.didAppear() } }
    func sourceRemovalDidDismiss(_ id: UUID) {
        guard let current = sourceRemoval, current.id == id else { return }
        current.invalidate(); sourceRemoval = nil; sourceRemovalDismissing = false
    }
    func cancelSourceRemoval(_ id: UUID) {
        guard let current = sourceRemoval, current.id == id, !current.isConfirming else { return }
        invalidateSourceRemoval()
    }
    public func invalidateSourceRemoval() {
        guard let current = sourceRemoval else { return }
        current.invalidate()
        if current.appeared { sourceRemovalDismissing = true }
        else { sourceRemoval = nil; sourceRemovalDismissing = false }
    }
}

extension WorkspaceSession {
    var canPresentSourceRemoval: Bool { sourceRemoval == nil && !sourceRemovalDismissing && savedToolRemoval == nil && workflowLaunch == nil }
    func prepareSourceRemoval(_ target: SavedSourceTarget, in store: WorkbenchModel) {
        guard !store.isShuttingDown, canPresentSourceRemoval else { return }
        let presentation = SourceRemovalPresentation(target); sourceRemoval = presentation; presentation.refresh(in: store)
    }
    func sourceRemovalDidAppear(_ id: UUID) { if sourceRemoval?.id == id { sourceRemoval?.didAppear() } }
    func sourceRemovalDidDismiss(_ id: UUID) {
        guard let current = sourceRemoval, current.id == id else { return }
        current.invalidate(); sourceRemoval = nil; sourceRemovalDismissing = false
    }
    func cancelSourceRemoval(_ id: UUID) {
        guard let current = sourceRemoval, current.id == id, !current.isConfirming else { return }
        invalidateSourceRemoval()
    }
    public func invalidateSourceRemoval() {
        guard let current = sourceRemoval else { return }
        current.invalidate()
        if current.appeared { sourceRemovalDismissing = true }
        else { sourceRemoval = nil; sourceRemovalDismissing = false }
    }
}
