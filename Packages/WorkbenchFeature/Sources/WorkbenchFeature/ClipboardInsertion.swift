import Foundation
import MacAdapters

extension WorkbenchModel {
    /// 此入口只由真实用户的剪贴板面板提交；模型没有自动输入能力。
    public func insertClipboardText(_ text: String, target: ClipboardPasteTarget, isCurrent: @MainActor () -> Bool) async throws {
        guard allowContextCapture, !isShuttingDown else { throw ClipboardPasteError.permissionRequired }
        try authorizeHostAction(id: "clipboard.insert", operation: .pasteClipboard,
                                resource: "\(target.identity.pid)|\(target.identity.launchDate?.timeIntervalSince1970 ?? 0)|" + fingerprint(text),
                                availableContext: [.window, .explicitInput])
        try await desktop.paste(text, target: target, isCurrent: isCurrent)
        // 仅说明事件已发出；不能证明外部应用消费、提交或保存了文本。
        recordDirectActivity(commandID: "clipboard.insert", category: .clipboard, outcome: .succeeded)
    }
}
