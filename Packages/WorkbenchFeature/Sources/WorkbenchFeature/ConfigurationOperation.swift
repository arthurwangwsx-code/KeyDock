import Foundation

struct ConfigurationOperation {
    let cancel: @Sendable () -> Void
    let wait: @MainActor () async -> Void
}

extension WorkbenchModel {
    /// 配置的异步清理也由App拥有；关闭sheet不丢失已经提交的连接收口。
    func trackConfigurationOperation<Value: Sendable>(_ task: Task<Value, Never>, id: UUID) {
        configurationOperations[id] = .init(cancel: { task.cancel() }, wait: { _ = await task.value })
    }
}
