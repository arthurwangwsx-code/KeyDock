import Foundation

extension WorkbenchModel {
    func scheduleTaskMaterialPermissionBarrier() {
        guard taskMaterialPermissionTask == nil else { return }
        taskMaterialPermissionChanging = true
        let writes = Array(taskMaterialSaveOperations.values)
        taskMaterialPermissionTask = Task { @MainActor [self] in
            await taskMaterialStore.barrier()
            for operation in writes { _ = try? await operation.value }
            taskMaterialPermissionChanging = false; taskMaterialPermissionTask = nil
        }
    }
    func scheduleTaskMaterialMaintenance() {
        guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing, taskMaterialMaintenanceTask == nil else { return }
        taskMaterialMaintenanceTask = Task { @MainActor [self] in
            defer { taskMaterialMaintenanceTask = nil }
            // 删除恢复不依赖history恢复UI快照是否过期；读取/维护只访问header和无正文control。
            let resumed = await taskMaterialStore.resumeDeletion()
            guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing else { return }
            do {
                let inventory = try await taskMaterialStore.inventory()
                let owners = inventory.handles.isEmpty ? Set<TaskMaterialKey>() : try await taskMaterialOwners()
                guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing else { return }
                let result = await taskMaterialStore.maintain(inventory, validOwners: owners)
                if !resumed.isComplete || !result.isComplete {
                    taskMaterialNotice = noticeKey("Some retained task content needs attention. Existing files were kept; review or clear it in Privacy settings.")
                }
                if taskMaterialGeneration != taskMaterialFence.current.generation { invalidateTaskMaterialBuffers(includeLoadedReads: true) }
                await refreshTaskMaterialIndex()
            } catch { if !isShuttingDown { taskMaterialNotice = taskMaterialErrorNotice(error) } }
        }
    }
    func maintainTaskMaterials() async {
        scheduleTaskMaterialMaintenance()
        await taskMaterialMaintenanceTask?.value
    }
    /// 自动metadata维护发生后，先撤销旧写入，再捕获正文inventory；不会删到后来创建的版本。
    func taskMaterialOwnersWereRemoved() {
        taskMaterialFence.invalidateContent(); invalidateTaskMaterialBuffers(includeLoadedReads: true)
    }
    func clearTaskMaterialOwners(_ keys: Set<TaskMaterialKey>) async -> TaskMaterialMutationReport {
        let id = UUID()
        let operation = Task { [taskMaterialStore] in await taskMaterialStore.clearOwners(keys) }
        taskMaterialMutationOperations[id] = operation
        let result = await operation.value
        taskMaterialMutationOperations[id] = nil
        if result.isComplete { for key in keys { taskMaterialHandles[key] = nil }; taskMaterialRecords.removeAll { keys.contains($0.id) } }
        taskMaterialGeneration = taskMaterialFence.current.generation
        return result
    }
    func clearTaskMaterials() async {
        guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing else { return }
        taskMaterialClearing = true
        revokeTaskMaterialCaptures(disabling: false)
        let id = UUID(), operation = Task { [taskMaterialStore] in await taskMaterialStore.clear() }
        taskMaterialMutationOperations[id] = operation
        let report = await operation.value
        taskMaterialMutationOperations[id] = nil; taskMaterialClearing = false
        guard !isShuttingDown else { return }
        taskMaterialGeneration = taskMaterialFence.current.generation
        if report.isComplete { taskMaterialHandles = [:]; taskMaterialRecords = [] }
        taskMaterialNotice = report.isComplete
            ? noticeKey("Retained task content cleared. Ordinary session results and running tasks were kept.")
            : noticeKey("Task content was only partly cleared. Some files remain. Try clearing again in Privacy settings.")
        await refreshTaskMaterialIndex()
    }
    func deleteTaskMaterial(_ handle: TaskMaterialHandle) async -> TaskMaterialMutationReport {
        guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing else { return .init(failure: .unavailable) }
        taskMaterialClearing = true
        taskMaterialFence.invalidateContent(); invalidateTaskMaterialBuffers(includeLoadedReads: true)
        let id = UUID(), operation = Task { [taskMaterialStore] in await taskMaterialStore.delete(handle) }
        taskMaterialMutationOperations[id] = operation
        let report = await operation.value
        taskMaterialMutationOperations[id] = nil; taskMaterialClearing = false
        guard !isShuttingDown else { return report }
        taskMaterialGeneration = taskMaterialFence.current.generation
        if report.isComplete { taskMaterialHandles[handle.key] = nil; taskMaterialRecords.removeAll { $0.id == handle.key } }
        else { taskMaterialNotice = noticeKey("Task content was only partly cleared. Some files remain. Try clearing again in Privacy settings.") }
        await refreshTaskMaterialIndex()
        return report
    }
}
