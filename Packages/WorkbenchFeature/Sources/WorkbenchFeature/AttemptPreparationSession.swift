import Foundation

extension WorkspaceSession {
    public var hasPendingOrDismissingModal: Bool {
        attemptPreparation != nil || attemptPreparationDismissing || sourceRemoval != nil || sourceRemovalDismissing ||
        workflowLaunch != nil || savedToolRemoval != nil
    }
    public func prepareAttempt(_ taskID: UUID, in store: WorkbenchModel) {
        guard !store.isShuttingDown, !hasPendingOrDismissingModal,
              let task = store.tasks.first(where: { $0.id == taskID }), !task.isRunning, task.runAttempt != nil else { return }
        let presentation = AttemptPreparationPresentation(.init(store: task.runAttempt?.definition.kind == .savedCommand ? .cli : .ai, invocationID: taskID))
        attemptPreparation = presentation
        presentation.refresh(in: store)
    }
    func attemptPreparationDidAppear(_ id: UUID) { if attemptPreparation?.id == id { attemptPreparation?.didAppear() } }
    func attemptPreparationDidDismiss(_ id: UUID) {
        guard let current = attemptPreparation, current.id == id else { return }
        let accepted = current.admittedTaskID
        current.invalidate(); attemptPreparation = nil; attemptPreparationDismissing = false
        if let accepted { selectedTaskID = accepted; page = .tasks }
    }
    func cancelAttemptPreparation(_ id: UUID) {
        guard let current = attemptPreparation, current.id == id, !current.isSubmitting, current.admittedTaskID == nil else { return }
        invalidateAttemptPreparation()
    }
    public func invalidateAttemptPreparation() {
        guard let current = attemptPreparation else { return }
        current.invalidate()
        if current.appeared { attemptPreparationDismissing = true }
        else { attemptPreparation = nil; attemptPreparationDismissing = false }
    }
    func workflowLaunchDidDismiss(_ id: UUID) {
        guard let current = workflowLaunch, current.id == id else { return }
        let accepted = current.startedTaskID
        workflowLaunch = nil
        if let accepted { selectedTaskID = accepted; page = .tasks }
    }
    func toolRemovalDidDismiss(_ id: UUID) { if savedToolRemoval?.id == id { savedToolRemoval = nil } }
    public func attemptHistoryChanged(_ removed: Set<UUID>, in store: WorkbenchModel) {
        guard let current = attemptPreparation else { return }
        if removed.contains(current.origin.invocationID) { current.sourceRemoved() }
        else { current.validateReview(in: store) }
    }
}
