import Foundation
import Combine

/// 同一正文缓冲只有一个owner；撤权/清除直接擦掉该对象，不留下UI侧的第二份缓存。
@MainActor final class TaskMaterialBuffer: ObservableObject, Identifiable {
    enum Purpose { case saveReview, retainedRead }
    let id = UUID()
    let key: TaskMaterialKey
    let purpose: Purpose
    @Published private(set) var material: SelectedTaskMaterial?
    private(set) var budgetedBytes: Int
    private(set) var invalidated = false
    private(set) var inFlight: Bool
    private(set) var saveClaimed = false
    init(key: TaskMaterialKey, purpose: Purpose, reservedBytes: Int, material: SelectedTaskMaterial? = nil, inFlight: Bool = false) {
        self.key = key; self.purpose = purpose; budgetedBytes = reservedBytes; self.material = material
        self.inFlight = inFlight
    }
    func publish(_ material: SelectedTaskMaterial) throws {
        guard !invalidated, material.rawBytes <= budgetedBytes else { throw TaskMaterialError.staleCheck }
        self.material = material; budgetedBytes = material.rawBytes
    }
    func finishRead() { inFlight = false; if invalidated { budgetedBytes = 0 } }
    func claimSave() throws {
        guard !invalidated, !saveClaimed else { throw TaskMaterialError.staleCheck }
        saveClaimed = true
    }
    func keepOnlyInput() throws {
        guard !invalidated, purpose == .retainedRead, let input = material?.input else { throw TaskMaterialError.invalidContent }
        material = .init(input: input); budgetedBytes = input.utf8.count
    }
    func clear() { invalidated = true; material = nil; if !inFlight { budgetedBytes = 0 } }
}
