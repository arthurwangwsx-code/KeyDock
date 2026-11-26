import CommandCore
import MacAdapters

extension WorkbenchModel {
    @discardableResult func validateApplicationActionSource() -> Bool {
        guard configuration.savedApplicationActions == nil else { return applicationActionsWritable }
        guard let source = legacyApplicationActions else { return false }
        do { try source.validateCurrent(); return true }
        catch {
            if applicationActionsWritable {
                applicationActionsWritable = false; configurationExportGeneration = .init()
                for lease in desktopLeases.values { lease.revoke() }
                rebuildCatalog()
            }
            return false
        }
    }
    /// 同步提交的写入端口也可能触发外部变化；发布canonical前再次核对旧源。
    func validatePreparedApplicationActionConfiguration(_ next: AppConfiguration) throws {
        try configurationDirectoryIdentity?.validateCurrent()
        if configuration.savedApplicationActions == nil, next.savedApplicationActions != nil {
            guard validateApplicationActionSource() else { throw ArchiveStoreError.externalChange }
        }
    }
    /// 旧源只在第一次成功主配置提交时转成canonical；未知源仍显式保存null。
    func preparedApplicationActionConfiguration(_ input: AppConfiguration) throws -> AppConfiguration {
        var next = input
        try configurationDirectoryIdentity?.validateCurrent()
        if configuration.savedApplicationActions != nil {
            guard next.savedApplicationActions != nil else { throw ArchiveStoreError.unavailable }
            return next
        }
        guard let source = legacyApplicationActions else {
            guard next.savedApplicationActions == nil else { throw ArchiveStoreError.unavailable }
            return next
        }
        guard validateApplicationActionSource() else {
            guard next.savedApplicationActions == nil else { throw ArchiveStoreError.externalChange }
            return next
        }
        if next.savedApplicationActions == nil { next.savedApplicationActions = source.actions }
        return next
    }
    func applicationActionRevision(_ action: SavedApplicationAction) -> String? {
        objectFingerprint(action).map { fingerprint($0 + "|" + applicationActionsEpoch.uuidString) }
    }
}
