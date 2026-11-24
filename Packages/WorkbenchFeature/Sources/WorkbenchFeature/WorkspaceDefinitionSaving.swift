import Foundation

enum WorkspaceDefinitionSaveState: Equatable {
    case notSaved, modified, saved(Int)

    var title: String {
        switch self {
        case .notSaved: L("Not saved")
        case .modified: L("Unsaved changes")
        case .saved(let version): L("Saved version") + ": \(version)"
        }
    }
    var symbol: String { if case .saved = self { "checkmark.circle" } else { "square.and.pencil" } }
}

extension WorkspaceSession {
    func agentProfileSaveState(in store: WorkbenchModel) -> WorkspaceDefinitionSaveState {
        guard let saved = store.configuration.agents.first(where: { $0.id == agentProfile.id }) else { return .notSaved }
        // Swift的String相等会折叠规范等价序列，保存状态仍应区分真实编辑字节。
        let exactText = saved.name.utf8.elementsEqual(agentProfile.name.utf8)
            && saved.instructions.utf8.elementsEqual(agentProfile.instructions.utf8)
            && saved.modelOverride.utf8.elementsEqual(agentProfile.modelOverride.utf8)
        return saved == agentProfile && exactText ? .saved(saved.version) : .modified
    }

    func workflowSaveState(in store: WorkbenchModel) -> WorkspaceDefinitionSaveState {
        guard let saved = store.configuration.workflows.first(where: { $0.id == workflowDraft.id }) else { return .notSaved }
        let exactText = saved.name.utf8.elementsEqual(workflowDraft.name.utf8)
            && zip(saved.steps, workflowDraft.steps).allSatisfy { old, draft in
                if case .literal(let left) = old.input, case .literal(let right) = draft.input { return left.utf8.elementsEqual(right.utf8) }
                return true
            }
        return saved == workflowDraft && exactText ? .saved(saved.version) : .modified
    }

    @discardableResult func saveAgentProfile(in store: WorkbenchModel) -> Bool {
        guard store.saveAgent(agentProfile), let saved = store.configuration.agents.first(where: { $0.id == agentProfile.id }) else { return false }
        agentProfile = saved
        return true
    }

    @discardableResult func saveWorkflow(in store: WorkbenchModel) -> Bool {
        guard store.saveWorkflow(workflowDraft), let saved = store.configuration.workflows.first(where: { $0.id == workflowDraft.id }) else { return false }
        workflowDraft = saved
        return true
    }
}
