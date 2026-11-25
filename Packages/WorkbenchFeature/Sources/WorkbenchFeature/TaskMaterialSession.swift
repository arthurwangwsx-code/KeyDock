import Foundation

extension WorkspaceSession {
    public var ownsTaskMaterialReview: Bool { taskMaterialPresentation != nil || taskMaterialDismissing }
    func prepareRetainedTaskMaterial(_ record: TaskMaterialListRecord, in store: WorkbenchModel) {
        guard !store.isShuttingDown, !hasPendingOrDismissingModal else { return }
        let presentation = TaskMaterialPresentation(key: record.id, mode: .view, title: record.title, titleKey: record.titleKey, store: store)
        taskMaterialPresentation = presentation; presentation.refresh(in: store)
    }
    func prepareTaskMaterial(_ taskID: UUID, mode: TaskMaterialPresentation.Mode, in store: WorkbenchModel) {
        guard !store.isShuttingDown, !hasPendingOrDismissingModal,
              let task = store.tasks.first(where: { $0.id == taskID }), let key = store.taskMaterialKey(task) else { return }
        let presentation = TaskMaterialPresentation(key: key, mode: mode, title: task.displayTitle, titleKey: task.titleKey, store: store)
        taskMaterialPresentation = presentation; presentation.refresh(in: store)
    }
    func taskMaterialDidAppear(_ id: UUID) { if taskMaterialPresentation?.id == id { taskMaterialPresentation?.didAppear() } }
    func taskMaterialDidDismiss(_ id: UUID) {
        guard let current = taskMaterialPresentation, current.id == id else { return }
        current.invalidate(); taskMaterialPresentation = nil; taskMaterialDismissing = false
    }
    func cancelTaskMaterial(_ id: UUID) {
        guard let current = taskMaterialPresentation, current.id == id, !current.isMutating else { return }
        invalidateTaskMaterialPresentation()
    }
    public func invalidateTaskMaterialPresentation() {
        guard let current = taskMaterialPresentation else { return }
        current.invalidate()
        if current.appeared { taskMaterialDismissing = true }
        else { taskMaterialPresentation = nil; taskMaterialDismissing = false }
    }
}
