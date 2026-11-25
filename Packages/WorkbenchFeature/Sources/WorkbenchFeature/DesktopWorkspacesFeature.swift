import Foundation
import Combine
import CommandCore
import MacAdapters

struct DesktopWorkspaceRowDraft: Identifiable, Equatable {
    var id = UUID()
    var applicationID = ""
    var layout: WindowLayout = .maximize
    var display: DesktopWorkspaceDisplayPolicy = .windowDisplay
    var missingApplication: DesktopWorkspaceMissingApplicationPolicy = .requireRunning
    init() {}
    init(_ entry: DesktopWorkspaceEntry) {
        id = entry.id; applicationID = entry.applicationID; layout = entry.layout
        display = entry.display; missingApplication = entry.missingApplication
    }
    func definition() throws -> DesktopWorkspaceEntry {
        try .init(id: id, applicationID: applicationID, layout: layout, display: display, missingApplication: missingApplication)
    }
}

@MainActor final class DesktopWorkspaceEditorDraft: ObservableObject, Identifiable {
    let id = UUID()
    let workspaceID: UUID
    let expectedRevision: Int?
    @Published var name: String
    @Published var rows: [DesktopWorkspaceRowDraft]
    @Published var notice: LocalizedNotice = .none
    init(_ initial: SavedDesktopWorkspace? = nil) {
        workspaceID = initial?.id ?? UUID(); expectedRevision = initial?.revision
        name = initial?.name ?? ""; rows = initial?.entries.map(DesktopWorkspaceRowDraft.init) ?? [.init()]
    }
    func definition() throws -> SavedDesktopWorkspace {
        try .init(id: workspaceID, revision: expectedRevision ?? 1, name: name, entries: rows.map { try $0.definition() })
    }
    func addRow() { if rows.count < SavedDesktopWorkspace.maximumEntries { rows.append(.init()) } }
    func removeRow(_ id: UUID) { rows.removeAll { $0.id == id } }
    func moveRow(_ id: UUID, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index+offset) else { return }
        rows.swapAt(index, index+offset)
    }
}

extension WorkbenchModel {
    @discardableResult func saveDesktopWorkspace(_ candidate: SavedDesktopWorkspace, expectedRevision: Int?) -> Bool {
        guard !isShuttingDown else { settingsNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return false }
        guard let storage = desktopWorkspaceStore, desktopWorkspacesWritable else { settingsNoticeMessage = noticeKey("Desktop workspaces are read-only. Existing data has been preserved."); return false }
        let current = desktopWorkspaces.first { $0.id == candidate.id }
        guard current?.revision == expectedRevision, candidate.revision == (expectedRevision ?? 1) else {
            settingsNoticeMessage = noticeKey("This workspace changed or was removed. Keep your draft and reopen it before saving."); return false
        }
        let existingApplications = Set(current?.entries.map(\.applicationID) ?? [])
        let available = Set(configurableApplications.map(\.id))
        guard candidate.entries.allSatisfy({ available.contains($0.applicationID) || existingApplications.contains($0.applicationID) }) else {
            settingsNoticeMessage = noticeKey("Choose an available application for each new workspace target."); return false
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let current, try encoder.encode(current) == encoder.encode(candidate) {
                try storage.validateCurrent(); settingsNoticeMessage = .none; return true
            }
            let revision: Int
            if let current {
                guard current.revision < Int.max else { throw DesktopWorkspaceValidationError.invalidDefinition }
                revision = current.revision+1
            } else { revision = 1 }
            let value = try SavedDesktopWorkspace(id: candidate.id, revision: revision, name: candidate.name, entries: candidate.entries)
            var next = desktopWorkspaces
            if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
            else { next.append(value) }
            try storage.save(next)
            cancelDesktopWorkspaceRuns(definitionID: candidate.id)
            desktopWorkspaces = storage.workspaces; desktopWorkspacesWritable = storage.writable; rebuildCatalog()
            settingsNoticeMessage = storage.writable ? .none : noticeKey("Workspace definitions were saved, but a recovery file remains. Further changes are disabled until checked.")
            return true
        } catch {
            desktopWorkspacesWritable = storage.writable
            settingsNoticeMessage = noticeKey("Workspace definitions could not be saved. Your draft and existing data were preserved.")
            return false
        }
    }
    @discardableResult func removeDesktopWorkspace(_ reviewed: SavedDesktopWorkspace) -> Bool {
        guard !isShuttingDown else { settingsNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return false }
        guard let storage = desktopWorkspaceStore, desktopWorkspacesWritable else { settingsNoticeMessage = noticeKey("Desktop workspaces are read-only. Existing data has been preserved."); return false }
        guard desktopWorkspaces.first(where: { $0.id == reviewed.id }) == reviewed else { settingsNoticeMessage = noticeKey("This workspace changed or was removed. Keep your draft and reopen it before saving."); return false }
        let id = reviewed.commandID
        guard configuration.commandShortcuts[id] == nil, !configuration.preferences.favorites.contains(id), (configuration.preferences.aliases[id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              !configuration.collections.contains(where: { $0.commandIDs.contains(id) }) else {
            settingsNoticeMessage = noticeKey("This workspace has saved references. Remove its shortcut, alias, favorite or collection references first."); return false
        }
        do {
            try storage.save(desktopWorkspaces.filter { $0.id != reviewed.id })
            cancelDesktopWorkspaceRuns(definitionID: reviewed.id)
            desktopWorkspaces = storage.workspaces; desktopWorkspacesWritable = storage.writable; rebuildCatalog()
            settingsNoticeMessage = storage.writable ? .none : noticeKey("Workspace definitions were saved, but a recovery file remains. Further changes are disabled until checked.")
            return true
        } catch {
            desktopWorkspacesWritable = storage.writable
            settingsNoticeMessage = noticeKey("Workspace definitions could not be saved. Your draft and existing data were preserved."); return false
        }
    }
}

extension SettingsSession {
    func beginDesktopWorkspace(_ value: SavedDesktopWorkspace? = nil, in store: WorkbenchModel) {
        guard !store.isShuttingDown, store.desktopWorkspacesWritable, desktopWorkspaceEditor == nil,
              editedCommand == nil, editedAction == nil, savedItemRemoval == nil, deletedToolPreferencesReview == nil else { return }
        desktopWorkspaceEditor = DesktopWorkspaceEditorDraft(value)
    }
    func cancelDesktopWorkspaceEdit(_ presentationID: UUID) {
        guard desktopWorkspaceEditor?.id == presentationID else { return }; desktopWorkspaceEditor = nil
    }
    @discardableResult func saveDesktopWorkspaceEdit(_ presentationID: UUID, in store: WorkbenchModel) -> Bool {
        guard let draft = desktopWorkspaceEditor, draft.id == presentationID else { return false }
        do {
            guard store.saveDesktopWorkspace(try draft.definition(), expectedRevision: draft.expectedRevision) else { draft.notice = store.settingsNoticeMessage; return false }
            desktopWorkspaceEditor = nil; return true
        } catch { draft.notice = noticeKey("Enter a short name and one to eight distinct applications with valid layouts."); return false }
    }
}

func workspaceDisplayTitle(_ policy: DesktopWorkspaceDisplayPolicy) -> String {
    switch policy { case .invocationDisplay: L("Screen used to invoke the workspace"); case .windowDisplay: L("Each window's original screen"); case .mainDisplay: L("Main screen") }
}
func workspaceMissingApplicationTitle(_ policy: DesktopWorkspaceMissingApplicationPolicy) -> String {
    switch policy { case .requireRunning: L("Require application already running"); case .launchInBackground: L("Allow background launch if missing") }
}
