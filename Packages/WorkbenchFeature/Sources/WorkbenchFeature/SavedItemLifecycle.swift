import Foundation
import CommandCore
import ExecutionCore
import AutomationCore
import Combine

enum SavedItemTarget: Equatable {
    case command(UUID), aiAction(UUID), snippet(UUID), webAction(UUID), collection(UUID)
    var commandID: String {
        switch self {
        case .command(let id): "command." + id.uuidString
        case .aiAction(let id): "ai." + id.uuidString
        case .snippet(let id): "snippet." + id.uuidString
        case .webAction(let id): "web." + id.uuidString
        case .collection(let id): "collection." + id.uuidString
        }
    }
    var isWorkspaceTool: Bool { switch self { case .snippet, .webAction, .collection: true; default: false } }
}

struct SavedItemDependency: Identifiable, Equatable {
    enum Kind: String { case workflow, agent, collection, schedule }
    let kind: Kind
    let objectID: UUID
    let name: String
    var id: String { kind.rawValue + "." + objectID.uuidString }
    var title: String {
        let category: String
        switch kind { case .workflow: category = L("Workflow"); case .agent: category = L("Agent profile"); case .collection: category = L("Collection"); case .schedule: category = L("Schedule name") }
        return category + ": " + name
    }
}

struct SavedItemRemovalReview: Identifiable {
    let id = UUID()
    let target: SavedItemTarget
    let name: String
    let fingerprint: String
    let dependencies: [SavedItemDependency]
}

/// sheet身份稳定，重新检查只替换审批快照，避免重建呈现时丢失键盘绑定。
@MainActor final class SavedItemRemovalPresentation: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var review: SavedItemRemovalReview
    init(_ review: SavedItemRemovalReview) { self.review = review }
    func update(_ review: SavedItemRemovalReview) { self.review = review }
}

extension WorkbenchModel {
    func reviewSavedItemRemoval(_ target: SavedItemTarget) -> SavedItemRemovalReview? {
        guard !isShuttingDown else { savedItemNotice(noticeKey("KeyDock is quitting. No new action was started."), for: target); return nil }
        guard let review = savedItemRemovalSnapshot(target) else {
            savedItemNotice(noticeKey("This saved item is no longer available."), for: target); return nil
        }
        savedItemNotice(.none, for: target)
        return review
    }

    func validateSavedToolEdit(_ target: SavedItemTarget, expected: String?) -> Bool {
        guard target.isWorkspaceTool, !isShuttingDown, let expected,
              savedItemRemovalSnapshot(target)?.fingerprint == expected else {
            workspaceNoticeMessage = noticeKey("This saved tool was removed or changed. Keep this draft and start a new item or edit the current version.")
            return false
        }
        return true
    }

    private func savedItemNotice(_ message: LocalizedNotice, for target: SavedItemTarget) {
        if target.isWorkspaceTool { workspaceNoticeMessage = message } else { settingsNoticeMessage = message }
    }

    /// 最终确认与持久化之间不悬挂；当前引用再次核对，不级联改写其他定义。
    @discardableResult func removeSavedItem(_ reviewed: SavedItemRemovalReview) -> Bool {
        guard !isShuttingDown else { savedItemNotice(noticeKey("KeyDock is quitting. No new action was started."), for: reviewed.target); return false }
        guard let current = savedItemRemovalSnapshot(reviewed.target) else {
            savedItemNotice(noticeKey("This saved item is no longer available."), for: reviewed.target); return false
        }
        guard current.fingerprint == reviewed.fingerprint, current.dependencies == reviewed.dependencies else {
            savedItemNotice(noticeKey("This saved item changed. Review it again before removing it."), for: reviewed.target); return false
        }
        guard current.dependencies.isEmpty else {
            savedItemNotice(noticeKey("This item is still in use. Remove its references, then review again."), for: reviewed.target); return false
        }
        var next = configuration
        switch reviewed.target {
        case .command(let id): next.savedCommands.removeAll { $0.id == id }
        case .aiAction(let id): next.aiActions.removeAll { $0.id == id }
        case .snippet(let id): next.snippets.removeAll { $0.id == id }
        case .webAction(let id): next.webActions.removeAll { $0.id == id }
        case .collection(let id): next.collections.removeAll { $0.id == id }
        }
        let commandID = reviewed.target.commandID
        next.commandShortcuts[commandID] = nil
        next.preferences.favorites.remove(commandID)
        next.preferences.aliases[commandID] = nil
        next.preferences.recent[commandID] = nil
        let saved = commitShortcutConfiguration(next)
        if reviewed.target.isWorkspaceTool { workspaceNoticeMessage = saved ? .none : settingsNoticeMessage }
        return saved
    }

    private func savedItemRemovalSnapshot(_ target: SavedItemTarget) -> SavedItemRemovalReview? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let name: String, bytes: Data
        switch target {
        case .command(let id):
            guard let value = configuration.savedCommands.first(where: { $0.id == id }), let data = try? encoder.encode(value) else { return nil }
            name = value.name; bytes = data
        case .aiAction(let id):
            guard let value = configuration.aiActions.first(where: { $0.id == id }), let data = try? encoder.encode(value) else { return nil }
            name = value.displayName; bytes = data
        case .snippet(let id):
            guard let value = configuration.snippets.first(where: { $0.id == id }), let data = try? encoder.encode(value) else { return nil }
            name = value.name; bytes = data
        case .webAction(let id):
            guard let value = configuration.webActions.first(where: { $0.id == id }), let data = try? encoder.encode(value) else { return nil }
            name = value.name; bytes = data
        case .collection(let id):
            guard let value = configuration.collections.first(where: { $0.id == id }), let data = try? encoder.encode(value) else { return nil }
            name = value.name; bytes = data
        }
        var dependencies: [SavedItemDependency] = []
        let workflows = configuration.workflows.filter { workflow in
            workflow.steps.contains { step in
                switch (target, step.operation) {
                case (.command(let id), .savedCommand(let used)), (.aiAction(let id), .aiAction(let used)): id == used
                default: false
                }
            }
        }
        let workflowIDs = Set(workflows.map(\.id))
        dependencies += workflows.map { .init(kind: .workflow, objectID: $0.id, name: $0.name) }
        if case .command(let id) = target {
            dependencies += configuration.agents.filter { $0.allowedCommandIDs.contains(id) }.map { .init(kind: .agent, objectID: $0.id, name: $0.name) }
        }
        let indirectIDs = Set(workflowIDs.map { "workflow." + $0.uuidString })
        dependencies += configuration.collections.filter { $0.commandIDs.contains(target.commandID) || $0.commandIDs.contains(where: { indirectIDs.contains($0) }) }
            .map { .init(kind: .collection, objectID: $0.id, name: $0.name) }
        dependencies += schedules.filter { workflowIDs.contains($0.definition.workflowID) }.map { .init(kind: .schedule, objectID: $0.id, name: $0.definition.name) }
        return .init(target: target, name: name, fingerprint: fingerprint(String(decoding: bytes, as: UTF8.self)), dependencies: dependencies.sorted { $0.id < $1.id })
    }
}

extension WorkspaceSession {
    func prepareToolRemoval(_ target: SavedItemTarget, in store: WorkbenchModel) {
        guard target.isWorkspaceTool, savedToolRemoval == nil, workflowLaunch == nil else { return }
        savedToolRemoval = store.reviewSavedItemRemoval(target).map(SavedItemRemovalPresentation.init)
    }
    func refreshToolRemoval(_ presentationID: UUID, in store: WorkbenchModel) {
        guard let current = savedToolRemoval, current.id == presentationID else { return }
        if let review = store.reviewSavedItemRemoval(current.review.target) { current.update(review) }
    }
    func cancelToolRemoval(_ presentationID: UUID) {
        guard savedToolRemoval?.id == presentationID else { return }; savedToolRemoval = nil
    }
    @discardableResult func confirmToolRemoval(_ reviewID: UUID, in store: WorkbenchModel) -> Bool {
        guard let current = savedToolRemoval, current.review.id == reviewID, store.removeSavedItem(current.review) else { return false }
        savedToolRemoval = nil
        return true
    }
}

extension SettingsSession {
    func editCommand(_ value: SavedCommand) {
        guard editedCommand == nil, editedAction == nil, savedItemRemoval == nil, deletedToolPreferencesReview == nil, desktopWorkspaceEditor == nil else { return }
        editedCommandExistingID = value.id; editedCommandSourceRunID = nil; editedCommand = value
    }
    func editAction(_ value: AIActionPreset) {
        guard editedCommand == nil, editedAction == nil, savedItemRemoval == nil, deletedToolPreferencesReview == nil, desktopWorkspaceEditor == nil else { return }
        editedActionExistingID = value.id; editedAction = value
    }
    func reviewCommand(_ value: SavedCommand, sourceRunID: UUID) {
        guard editedCommand == nil, editedAction == nil, savedItemRemoval == nil, deletedToolPreferencesReview == nil, desktopWorkspaceEditor == nil else { return }
        editedCommandExistingID = nil; editedCommandSourceRunID = sourceRunID; editedCommand = value
    }
    @discardableResult func saveEditedCommand(_ value: SavedCommand, in store: WorkbenchModel) -> Bool {
        let exists = store.configuration.savedCommands.contains { $0.id == value.id }
        guard editedCommand?.id == value.id, editedCommandExistingID.map({ $0 == value.id && exists }) ?? !exists else {
            store.settingsNoticeMessage = noticeKey("This command was removed or changed. Keep this draft and create a new command to save it."); return false
        }
        return store.saveCommand(value)
    }
    @discardableResult func saveEditedAction(_ value: AIActionPreset, in store: WorkbenchModel) -> Bool {
        let exists = store.configuration.aiActions.contains { $0.id == value.id }
        guard editedAction?.id == value.id, editedActionExistingID.map({ $0 == value.id && exists }) ?? !exists else {
            store.settingsNoticeMessage = noticeKey("This AI action was removed or changed. Keep this draft and create a new action to save it."); return false
        }
        return store.saveAction(value)
    }
    func prepareRemoval(_ target: SavedItemTarget, in store: WorkbenchModel) {
        guard editedCommand == nil, editedAction == nil, savedItemRemoval == nil, deletedToolPreferencesReview == nil, desktopWorkspaceEditor == nil else { return }
        savedItemRemoval = store.reviewSavedItemRemoval(target).map(SavedItemRemovalPresentation.init)
    }
    func refreshRemoval(_ presentationID: UUID, in store: WorkbenchModel) {
        guard let current = savedItemRemoval, current.id == presentationID else { return }
        if let refreshed = store.reviewSavedItemRemoval(current.review.target) { current.update(refreshed) }
    }
    func cancelRemoval(_ presentationID: UUID) {
        guard savedItemRemoval?.id == presentationID else { return }; savedItemRemoval = nil
    }
    @discardableResult func confirmRemoval(_ reviewID: UUID, in store: WorkbenchModel) -> Bool {
        guard let current = savedItemRemoval, current.review.id == reviewID, store.removeSavedItem(current.review) else { return false }
        savedItemRemoval = nil
        return true
    }
}
