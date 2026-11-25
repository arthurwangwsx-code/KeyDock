import Foundation
import Combine

@MainActor final class TaskMaterialPresentation: ObservableObject, Identifiable {
    enum Mode { case saveReview, view }
    enum Phase: Equatable { case idle, reading(UUID), ready, saving(UUID), deleting(UUID), saved, deleted, unavailable, closed }
    let id = UUID()
    let key: TaskMaterialKey
    let mode: Mode
    let title: String
    let titleKey: String?
    var displayTitle: String { titleKey.map(L) ?? title }
    @Published private(set) var reviewID = UUID()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var buffer: TaskMaterialBuffer?
    @Published private(set) var handle: TaskMaterialHandle?
    @Published var selectedFields: Set<TaskMaterialField> = []
    @Published var deletionChecked = false
    @Published private(set) var notice: LocalizedNotice = .none
    private(set) var appeared = false
    private weak var owner: WorkbenchModel?
    private var operation: Task<Void, Never>?
    var isReading: Bool { if case .reading = phase { true } else { false } }
    var isMutating: Bool { if case .saving = phase { true } else if case .deleting = phase { true } else { false } }
    var shouldDismiss: Bool { phase == .closed || phase == .deleted }
    var canSave: Bool { mode == .saveReview && phase == .ready && !selectedFields.isEmpty && buffer?.invalidated == false }
    init(key: TaskMaterialKey, mode: Mode, title: String, titleKey: String? = nil, store: WorkbenchModel) {
        self.key = key; self.mode = mode; self.title = title; self.titleKey = titleKey; owner = store
    }
    func didAppear() { if !shouldDismiss { appeared = true } }
    @discardableResult func refresh(in store: WorkbenchModel) -> Task<Void, Never>? {
        guard !isMutating, !shouldDismiss else { return nil }
        operation?.cancel(); releaseBuffer(); selectedFields = []; deletionChecked = false; handle = nil
        let token = UUID(); reviewID = UUID(); phase = .reading(token); notice = .none
        let generation = store.taskMaterialFence.current.generation
        operation = Task { [weak self] in
            var acquired: TaskMaterialBuffer?
            do {
                guard let self, self.phase == .reading(token) else { return }
                if mode == .saveReview { acquired = try store.freezeTaskMaterialReview(key.invocationID) }
                guard try await store.materialOwnerExists(key) else { throw TaskMaterialError.missing }
                let current = try await store.taskMaterialStore.inspect(key)
                if mode == .view {
                    guard let current else { throw TaskMaterialError.missing }
                    acquired = try await store.readTaskMaterial(current)
                }
                guard self.phase == .reading(token), !Task.isCancelled, !store.isShuttingDown,
                      store.taskMaterialFence.current.generation == generation, let acquired, !acquired.invalidated else {
                    if let acquired { store.releaseTaskMaterialBuffer(acquired.id) }
                    if self.phase == .reading(token) {
                        phase = .unavailable; operation = nil; notice = store.taskMaterialErrorNotice(TaskMaterialError.changed)
                    }
                    return
                }
                buffer = acquired; handle = current; phase = .ready; operation = nil
            } catch {
                if let acquired { store.releaseTaskMaterialBuffer(acquired.id) }
                guard let self, self.phase == .reading(token) else { return }
                notice = store.taskMaterialErrorNotice(error); phase = .unavailable; operation = nil
            }
        }
        return operation
    }
    @discardableResult func save(_ checkedReview: UUID, in store: WorkbenchModel) -> Task<Void, Never>? {
        guard canSave, reviewID == checkedReview, let buffer, let frozen = buffer.material else { return nil }
        let chosen = selectedFields, token = UUID()
        let result = chosen.contains(.visibleResult)
        let selected = SelectedTaskMaterial(input: chosen.contains(.input) ? frozen.input : nil,
            visibleResult: result ? frozen.visibleResult : nil, resultKind: result ? frozen.resultKind : nil,
            resultWasPartial: result ? frozen.resultWasPartial : nil, resultCapturedAt: result ? frozen.resultCapturedAt : nil,
            successfulCheckpoint: chosen.contains(.successfulCheckpoint) ? frozen.successfulCheckpoint : nil)
        let worker: Task<TaskMaterialHandle, Error>
        do { worker = try store.startTaskMaterialSave(selected, buffer: buffer, expected: handle?.version) }
        catch { notice = store.taskMaterialErrorNotice(error); releaseBuffer(); phase = .unavailable; return nil }
        phase = .saving(token)
        operation = Task { [weak self] in
            do {
                let saved = try await worker.value
                guard let self, phase == .saving(token), reviewID == checkedReview else { return }
                handle = saved; phase = .saved; notice = noticeKey("Selected task content saved on this Mac."); operation = nil
            } catch {
                guard let self, phase == .saving(token) else { return }
                notice = store.taskMaterialErrorNotice(error); releaseBuffer(); phase = .unavailable; operation = nil
            }
        }
        return operation
    }
    @discardableResult func delete(_ checkedReview: UUID, in store: WorkbenchModel) -> Task<Void, Never>? {
        guard mode == .view, phase == .ready, deletionChecked, reviewID == checkedReview, let handle else { return nil }
        let token = UUID(); phase = .deleting(token)
        operation = Task { [weak self] in
            let result = await store.deleteTaskMaterial(handle)
            guard let self, phase == .deleting(token), reviewID == checkedReview else { return }
            releaseBuffer(); operation = nil
            if result.isComplete { phase = .deleted }
            else { phase = .unavailable; notice = store.taskMaterialNotice }
        }
        return operation
    }
    func contentChanged(in store: WorkbenchModel) {
        if case .deleting = phase { return }
        if isReading {
            operation?.cancel(); operation = nil; releaseBuffer(); phase = .unavailable
            notice = store.taskMaterialErrorNotice(TaskMaterialError.changed); return
        }
        if mode == .saveReview, !store.taskMaterialFence.current.enabled || buffer?.invalidated == true {
            operation?.cancel(); releaseBuffer(); phase = .unavailable
            notice = store.taskMaterialErrorNotice(TaskMaterialError.permissionDenied)
        } else if buffer?.invalidated == true {
            operation?.cancel(); releaseBuffer(); phase = .unavailable
            notice = store.taskMaterialErrorNotice(TaskMaterialError.changed)
        }
    }
    func invalidate() { phase = .closed; operation?.cancel(); operation = nil; releaseBuffer() }
    private func releaseBuffer() {
        if let buffer { owner?.releaseTaskMaterialBuffer(buffer.id) }
        buffer = nil
    }
}
