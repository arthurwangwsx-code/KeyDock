import Foundation

/// 槽位替换或取消不等于worker完成；持有到实际返回，关闭时封住新任务并等待全部收口。
@MainActor public final class OwnedTaskLifetime {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    public var activeCount: Int { tasks.count }
    public init() {}
    @discardableResult public func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !closed else { return nil }
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            if !Task.isCancelled { await operation() }
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }
    public func close() {
        closed = true
        for task in tasks.values { task.cancel() }
    }
    public func shutdownAndWait() async {
        close()
        while let task = tasks.values.first { await task.value }
    }
}
