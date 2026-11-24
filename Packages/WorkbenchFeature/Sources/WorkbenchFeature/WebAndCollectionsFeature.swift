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
    func removeWebAction(_ id:UUID) { var next = configuration; next.webActions.removeAll{$0.id == id}; _ = commitSettingsConfiguration(next) }
    @discardableResult func saveCollection(id:UUID?,name:String,commandIDs:[String]) -> Bool {
        do {
            let value = try CommandCollection(id:id ?? UUID(),name:name,commandIDs:commandIDs)
            guard value.commandIDs.allSatisfy({id in catalog.contains{$0.id == id && $0.kind != .window}}) else { throw CommandCollectionValidationError.invalidCommandID }
            var next = configuration
            if let index = next.collections.firstIndex(where:{$0.id == value.id}) { next.collections[index] = value }
            else { guard next.collections.count < 32 else { return false }; next.collections.append(value) }
            return commitSettingsConfiguration(next)
        } catch { workspaceNoticeMessage = noticeKey("Collection could not be saved. Choose up to 32 available actions."); return false }
    }
    func removeCollection(_ id:UUID) { var next = configuration; next.collections.removeAll{$0.id == id}; _ = commitSettingsConfiguration(next) }
}
