import Foundation
import ExecutionCore

extension WorkbenchModel {
    /// 工作区提交共用设置事务，同时把失败反馈留在发起操作的窗口。
    @discardableResult func commitWorkspaceConfiguration(_ next: AppConfiguration) -> Bool {
        let saved = commitSettingsConfiguration(next)
        workspaceNoticeMessage = saved ? .none : settingsNoticeMessage
        return saved
    }

    /// 先持久化候选，成功后才更新界面；写入后抛错也补偿旧文件。
    @discardableResult func commitSettingsConfiguration(_ input: AppConfiguration) -> Bool {
        if isDesktopReview { return commitDesktopReviewConfiguration(input) }
        let next: AppConfiguration
        do { next = try preparedApplicationActionConfiguration(preparedAIConfiguration(input)) }
        catch { settingsNoticeMessage = noticeKey("Application actions changed or remain unconfirmed. Restart and review their source before changing them."); return false }
        guard !isShuttingDown else { settingsNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return false }
        let url = directory.appendingPathComponent("configuration.json")
        do {
            let snapshot: ConfigurationSnapshot = FileManager.default.fileExists(atPath: url.path)
                ? .bytes(try Data(contentsOf: url)) : .absent
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try configurationDirectoryIdentity?.validateCurrent()
                try configurationWriter(encoder.encode(next), url)
                try validatePreparedApplicationActionConfiguration(next)
            } catch {
                do { try restoreConfiguration(snapshot, at: url) }
                catch { settingsNoticeMessage = noticeKey("Settings could not be saved and the previous file could not be restored. Check settings before restarting."); return false }
                throw error
            }
            configuration = next; applyConfigurationEffects(); settingsNoticeMessage = .none
            return true
        } catch { settingsNoticeMessage = noticeKey("Configuration could not be saved"); return false }
    }
}
