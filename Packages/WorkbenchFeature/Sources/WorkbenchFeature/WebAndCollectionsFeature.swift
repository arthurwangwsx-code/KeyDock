import AppKit
import Foundation
import CommandCore
import ExecutionCore

extension WorkbenchModel {
    @discardableResult func saveWebAction(id:UUID?,name:String,template:String) -> Bool {
        // 带ID只代表显式编辑；目标删除后不能通过旧草稿隐式复活。
        if let id, !configuration.webActions.contains(where: { $0.id == id }) {
            workspaceNoticeMessage = noticeKey("This URL action no longer exists. Start a new action to save this draft.")
            return false
        }
        do {
            let value = try WebActionDefinition(id:id ?? UUID(),name:name,urlTemplate:template)
            var next = configuration
            if let index = next.webActions.firstIndex(where:{$0.id == value.id}) { next.webActions[index] = value }
            else {
                guard next.webActions.count < 100 else {
                    workspaceNoticeMessage = noticeKey("URL action limit reached. Remove an action before adding another.")
                    return false
                }
                next.webActions.append(value)
            }
            guard commitSettingsConfiguration(next) else {
                workspaceNoticeMessage = settingsNoticeMessage
                return false
            }
            workspaceNoticeMessage = .none
            return true
        } catch { workspaceNoticeMessage = noticeKey("Use a valid HTTP or HTTPS URL. One {query} placeholder is allowed in the query section."); return false }
    }
    func openWebAction(_ id:UUID,query:String? = nil,caller:ExecutionCaller = .user) {
        guard let action = configuration.webActions.first(where:{$0.id == id}) else { return }
        do {
            let url = try action.resolvedURL(query:query)
            try authorizeHostAction(id:"web."+id.uuidString,operation:.openURL,resource:url.absoluteString,caller:caller)
            guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
            recordDirectActivity(commandID:"web."+id.uuidString,category:.utility,outcome:.succeeded)
        } catch { workspaceNoticeMessage = noticeKey("URL could not be opened. Check the saved address and query.") }
    }
    @discardableResult func removeWebAction(_ id:UUID) -> Bool {
        var next = configuration; next.webActions.removeAll { $0.id == id }
        guard commitSettingsConfiguration(next) else { workspaceNoticeMessage = settingsNoticeMessage; return false }
        workspaceNoticeMessage = .none
        return true
    }
    @discardableResult func saveCollection(id:UUID?,name:String,commandIDs:[String]) -> Bool {
        if let id, !configuration.collections.contains(where: { $0.id == id }) {
            workspaceNoticeMessage = noticeKey("This collection no longer exists. Start a new collection to save this draft.")
            return false
        }
        do {
            let value = try CommandCollection(id:id ?? UUID(),name:name,commandIDs:commandIDs)
            guard value.commandIDs.allSatisfy({ collectionAction($0) != nil }) else { throw CommandCollectionValidationError.invalidCommandID }
            var next = configuration
            if let index = next.collections.firstIndex(where:{$0.id == value.id}) { next.collections[index] = value }
            else {
                guard next.collections.count < 32 else {
                    workspaceNoticeMessage = noticeKey("Collection limit reached. Remove a collection before adding another.")
                    return false
                }
                next.collections.append(value)
            }
            guard commitSettingsConfiguration(next) else { workspaceNoticeMessage = settingsNoticeMessage; return false }
            workspaceNoticeMessage = .none
            return true
        } catch { workspaceNoticeMessage = noticeKey("Collection could not be saved. Choose up to 32 available actions."); return false }
    }
    @discardableResult func removeCollection(_ id:UUID) -> Bool {
        var next = configuration; next.collections.removeAll { $0.id == id }
        guard commitSettingsConfiguration(next) else { workspaceNoticeMessage = settingsNoticeMessage; return false }
        workspaceNoticeMessage = .none
        return true
    }
    func runCollectionAction(_ id: String, caller: ExecutionCaller = .user) {
        guard !isShuttingDown else { workspaceNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return }
        guard let item = collectionAction(id) else { workspaceNoticeMessage = noticeKey("Unavailable action"); return }
        guard isCollectionActionEnabled(id) else { contributionUnavailable(); return }
        if item.kind == .ai {
            do { try authorizeHostItem(item, caller: caller) }
            catch { workspaceNoticeMessage = errorNotice(error); return }
            guard let action = configuration.aiActions.first(where: { "ai." + $0.id.uuidString == id }) else { return }
            // 工作区没有唤起前目标。先打开明确的手动草稿，不读取剪贴板或触发模型。
            let draft = createDraft(actionID: action.id, input: "", target: nil, source: .manual, caller: caller)
            if ownsDraft(draft) { onOpenWorkspace?(.ai(draft.id)) }
        } else if item.kind == .command {
            guard let command = configuration.savedCommands.first(where: { "command." + $0.id.uuidString == id }) else { return }
            let previousSettings = settingsNoticeMessage, previousLauncher = launcherNoticeMessage
            if runCommand(command, caller: caller, showWorkspace: true) == nil {
                if settingsNoticeMessage != previousSettings { workspaceNoticeMessage = settingsNoticeMessage }
                else if launcherNoticeMessage != previousLauncher { workspaceNoticeMessage = launcherNoticeMessage }
                else { workspaceNoticeMessage = noticeKey("Command could not be started. Check its configuration and permissions.") }
            }
        } else { execute(item, caller: caller) }
    }
    private func isCollectionAction(_ item: CommandItem) -> Bool {
        item.kind != .window && item.kind != .clipboard && !item.id.hasPrefix("collection.") && !item.payload.hasPrefix("window-layout.") && !item.payload.hasPrefix("window-command.")
    }
    var collectionActions: [CommandItem] {
        let active = catalog.filter(isCollectionAction)
        guard !isContributionEnabled(BuiltinContributionID.commands) else { return active }
        return active + configuration.savedCommands.map { CommandItem(id:"command."+$0.id.uuidString,title:$0.name,subtitle:$0.executable,kind:.command,payload:$0.id.uuidString) }
    }
    func isCollectionActionEnabled(_ id:String) -> Bool {
        guard let item = collectionAction(id) else { return false }
        return contributions.owner(of:item).map { isContributionEnabled($0.manifest.reference.toolID) } ?? true
    }
    func collectionAction(_ id: String) -> CommandItem? {
        collectionActions.first { $0.id == id }
    }
}
