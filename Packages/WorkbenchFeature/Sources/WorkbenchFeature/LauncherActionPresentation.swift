import CommandCore

extension WorkbenchModel {
    /// 展示使用当前受信目录的动作声明；此处不准备输入、不授权或执行handler。
    public func launcherPrimaryActionTitle(for item: CommandItem) -> String {
        if let binding = item.contribution {
            guard contributions.owner(of: item) != nil,
                  let resolved = try? resolveContribution(binding, id: item.id, title: item.title, keywords: item.keywords) else { return L("Unavailable") }
            return L(resolved.action.title)
        }
        if contributions.owner(of: item) != nil { return L("Unavailable") }
        switch item.kind {
        case .command, .ai: return L("Run")
        case .window: return L("Switch")
        default: return L("Open")
        }
    }
}
