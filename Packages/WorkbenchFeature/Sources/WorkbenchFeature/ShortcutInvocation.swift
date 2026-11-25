import CommandCore

/// 在按键回调收到时冻结；等待原选区期间的开关或定义变化不得升级为一次新调用。
public struct ShortcutInvocation {
    let item: CommandItem
}

extension WorkbenchModel {
    public func prepareShortcutInvocation(id:String) -> ShortcutInvocation? {
        guard !isShuttingDown, let item = catalog.first(where:{$0.id == id}) else {
            launcherNoticeMessage = noticeKey("The shortcut target is no longer available"); return nil
        }
        return .init(item:item)
    }
    public func performCommand(_ invocation:ShortcutInvocation) {
        let frozen = invocation.item
        guard !isShuttingDown, let current = catalog.first(where:{$0.id == frozen.id}),
              current.kind == frozen.kind, current.payload == frozen.payload,
              current.objectRevision == frozen.objectRevision, current.contribution == frozen.contribution else {
            launcherNoticeMessage = noticeKey("The shortcut target is no longer available"); return
        }
        execute(current,caller:.shortcut)
    }
}
