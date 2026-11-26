import Foundation

/// 仅描述补偿结果；不把底层错误、路径或凭据正文拼入用户提示。
enum APIConfigurationPersistenceError: Error {
    case restored
    case rollbackIncomplete
}

enum ConfigurationSnapshot {
    case absent
    case bytes(Data)
}

extension WorkbenchModel {
    /// 配置在本方法成功返回后才发布；跨 Keychain/文件失败时分别补偿，并验证旧状态。
    func persistAPIConfiguration(_ next: AppConfiguration, apiKey: String) throws {
        try requireGeneralRuntime()
        let bytes = try JSONEncoder().encode(next)
        let url = directory.appendingPathComponent("configuration.json")
        let previousFile: ConfigurationSnapshot = FileManager.default.fileExists(atPath: url.path)
            ? .bytes(try Data(contentsOf: url)) : .absent
        let updateCredential = allowContextCapture && !apiKey.isEmpty
        // 读取的是即将被更新的 endpoint 槽位；切换服务时不能误删或覆盖旧服务的 key。
        let previousKey = updateCredential ? try credentialReader(next.endpoint) : nil
        var credentialAttempted = false
        do {
            if updateCredential {
                // 即使 writer 在实际更新后抛错，也必须检查并补偿这个槽位。
                credentialAttempted = true
                try credentialWriter(apiKey, next.endpoint)
            }
            try configurationWriter(bytes, url)
        } catch {
            var rollbackIncomplete = false
            if credentialAttempted {
                do { try restoreCredential(previousKey, account: next.endpoint) }
                catch { rollbackIncomplete = true }
            }
            // 凭据补偿失败也不能跳过文件补偿；两项都尽力收口。
            do { try restoreConfiguration(previousFile, at: url) }
            catch { rollbackIncomplete = true }
            throw rollbackIncomplete ? APIConfigurationPersistenceError.rollbackIncomplete : .restored
        }
    }

    private func restoreCredential(_ previousKey: String?, account: String) throws {
        // 新写入若未生效，无需多做一次修改；读取失败时仍尝试恢复已知旧值。
        do { if try credentialReader(account) == previousKey { return } }
        catch { /* 无法确认当前值，继续恢复；不把读取失败误当“不存在”。 */ }
        try credentialWriter(previousKey ?? "", account)
        guard try credentialReader(account) == previousKey else { throw APIConfigurationPersistenceError.rollbackIncomplete }
    }

    func restoreConfiguration(_ snapshot: ConfigurationSnapshot, at url: URL) throws {
        try requireGeneralRuntime()
        switch snapshot {
        case .bytes(let previousBytes):
            if (try? Data(contentsOf: url)) == previousBytes { return }
            try configurationWriter(previousBytes, url)
            guard try Data(contentsOf: url) == previousBytes else { throw APIConfigurationPersistenceError.rollbackIncomplete }
        case .absent:
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw APIConfigurationPersistenceError.rollbackIncomplete }
        }
    }
}
