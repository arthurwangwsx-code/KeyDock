import AppKit

/// 只读当前编辑器的组合态；未提交候选不能被菜单或按钮当作可运行输入。
@MainActor public enum KDTextInputState {
    public static func permitsAction(in responder: NSResponder?) -> Bool {
        let editor = (responder as? NSControl)?.currentEditor() ?? responder
        return (editor as? any NSTextInputClient)?.hasMarkedText() != true
    }
    public static var permitsCurrentAction: Bool {
        permitsAction(in: NSApp?.keyWindow?.firstResponder)
    }
}
