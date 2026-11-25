import CommandCore

/// 在按键回调收到时冻结；等待原选区期间的开关或定义变化不得升级为一次新调用。
public struct ShortcutInvocation {
    let item: CommandItem
}

extension WorkbenchModel {
    public func isSavedToolShortcut(_ id: String) -> Bool {
        ["snippet.", "web.", "collection."].contains { id.hasPrefix($0) }
    }
    public func prepareSavedToolShortcut(id: String) -> ShortcutInvocation? {
        guard isSavedToolShortcut(id) else { return nil }
        guard let invocation = prepareShortcutInvocation(id: id) else {
            workspaceNoticeMessage = launcherNoticeMessage
            return nil
        }
        return invocation
    }
    public func prepareShortcutInvocation(id:String) -> ShortcutInvocation? {
        guard !isShuttingDown, let item = catalog.first(where:{$0.id == id}) else {
            launcherNoticeMessage = noticeKey("The shortcut target is no longer available"); return nil
        }
        return .init(item:item)
    }
    public func performCommand(_ invocation:ShortcutInvocation) {
        let frozen = invocation.item
        guard !isShuttingDown, isCurrentCommandItem(frozen), let current = catalog.first(where:{$0.id == frozen.id}) else {
            launcherNoticeMessage = noticeKey("The shortcut target is no longer available"); return
        }
        execute(current,caller:.shortcut)
    }
    func isCurrentCommandItem(_ item: CommandItem) -> Bool {
        guard let current = catalog.first(where: { $0.id == item.id }) else { return false }
        return current.kind == item.kind && current.payload == item.payload && current.objectRevision == item.objectRevision && current.contribution == item.contribution
    }
}
