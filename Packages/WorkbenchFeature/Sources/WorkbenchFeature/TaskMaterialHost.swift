import Foundation
import ExecutionCore

extension WorkbenchModel {
    func taskMaterialKey(_ task: RunningTaskItem) -> TaskMaterialKey? {
        guard let metadata = task.runAttempt else { return nil }
        return .init(receiptStore: task.receiptIsAI ? .ai : .cli, invocationID: task.id, receiptRecordIdentity: metadata.recordIdentity)
    }
    func materialOwnerExists(_ key: TaskMaterialKey) async throws -> Bool {
        let store = key.receiptStore == .cli ? invocationStore : aiInvocationStore
        guard let owner = try await store.materialOwner(key.invocationID) else { return false }
        return owner.recordIdentity == key.receiptRecordIdentity && (owner.kind == .savedCommand) == (key.receiptStore == .cli)
    }
    func releaseTaskMaterialBuffer(_ id: UUID) {
        guard let buffer = taskMaterialBuffers[id] else { return }
        buffer.clear()
        if !buffer.inFlight { taskMaterialBuffers[id] = nil }
    }
    func invalidateTaskMaterialBuffers(includeLoadedReads: Bool) {
        for buffer in Array(taskMaterialBuffers.values) where includeLoadedReads || buffer.purpose == .saveReview || buffer.material == nil {
            releaseTaskMaterialBuffer(buffer.id)
        }
        taskMaterialIndexRequest = UUID(); taskMaterialGeneration = taskMaterialFence.current.generation
    }

    /// 冻结指定时刻的可见正文；不从后来草稿推断输入，取消审阅不写任何正文文件。
    func freezeTaskMaterialReview(_ id: UUID) throws -> TaskMaterialBuffer {
        guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing, taskMaterialFence.current.enabled,
              let task = tasks.first(where: { $0.id == id }), let key = taskMaterialKey(task) else { throw TaskMaterialError.permissionDenied }
        let capture = taskMaterialCaptures[id]?.snapshot()
        guard capture == nil || capture?.key == key else { throw TaskMaterialError.changed }
        let hasResult = !task.output.isEmpty && !task.restoredFromReceipt && task.status != .handedOff
        let material = SelectedTaskMaterial(input: capture?.input, visibleResult: hasResult ? task.output : nil,
            resultKind: hasResult ? (task.runAttempt?.definition.kind == .agent ? .agentIncludingToolReturns : .visibleResult) : nil,
            resultWasPartial: hasResult ? (task.isRunning || task.outputIsIncomplete || task.status != .completed) : nil,
            resultCapturedAt: hasResult ? Date().timeIntervalSince1970 : nil, successfulCheckpoint: capture?.successfulCheckpoint)
        try material.validate(for: key)
        let protection = UUID(); visibleTaskReferences[protection] = id
        defer { visibleTaskReferences[protection] = nil }
        guard makeSessionRoom(additionalBytes: material.rawBytes), tasks.contains(where: { $0.id == id && taskMaterialKey($0) == key }) else { throw TaskMaterialError.capacity }
        let buffer = TaskMaterialBuffer(key: key, purpose: .saveReview, reservedBytes: material.rawBytes, material: material)
        taskMaterialBuffers[buffer.id] = buffer
        return buffer
    }

    /// 读取和解析的完整预算从await前保留到真实worker收口；取消仅撤销发布资格。
    func readTaskMaterial(_ handle: TaskMaterialHandle) async throws -> TaskMaterialBuffer {
        guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing else { throw TaskMaterialError.unavailable }
        let reservation = 2 * (TaskMaterialLimits.inputBytes + TaskMaterialLimits.outputBytes)
        guard makeSessionRoom(additionalBytes: reservation) else { throw TaskMaterialError.capacity }
        let buffer = TaskMaterialBuffer(key: handle.key, purpose: .retainedRead, reservedBytes: reservation, inFlight: true)
        taskMaterialBuffers[buffer.id] = buffer
        let generation = taskMaterialFence.current.generation
        let operation = Task { @MainActor [self] () throws -> TaskMaterialBuffer in
            defer {
                buffer.finishRead(); taskMaterialReadOperations[buffer.id] = nil
                if buffer.invalidated { taskMaterialBuffers[buffer.id] = nil }
            }
            do {
                try Task.checkCancellation()
                guard try await materialOwnerExists(handle.key) else { throw TaskMaterialError.missing }
                try Task.checkCancellation()
                let material = try await taskMaterialStore.read(handle, expectedGeneration: generation)
                try Task.checkCancellation()
                guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing, !buffer.invalidated,
                      taskMaterialFence.current.generation == generation,
                      try await materialOwnerExists(handle.key) else { throw TaskMaterialError.staleCheck }
                guard !buffer.invalidated, taskMaterialFence.current.generation == generation, !Task.isCancelled else { throw TaskMaterialError.staleCheck }
                try buffer.publish(material)
                return buffer
            } catch { buffer.clear(); throw error }
        }
        taskMaterialReadOperations[buffer.id] = operation
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }

    func saveTaskMaterial(_ selected: SelectedTaskMaterial, buffer: TaskMaterialBuffer,
                          expected: TaskMaterialVersion?) async throws -> TaskMaterialHandle {
        try await startTaskMaterialSave(selected, buffer: buffer, expected: expected).value
    }
    func startTaskMaterialSave(_ selected: SelectedTaskMaterial, buffer: TaskMaterialBuffer,
                               expected: TaskMaterialVersion?) throws -> Task<TaskMaterialHandle, Error> {
        guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing, !buffer.invalidated,
              buffer.purpose == .saveReview, taskMaterialBuffers[buffer.id] === buffer,
              taskMaterialFence.current.enabled else { throw TaskMaterialError.permissionDenied }
        try selected.validate(for: buffer.key)
        // UI选择只能减去审阅字段，不能借同一缓冲票据提交另一份正文。
        guard let frozen = buffer.material,
              selected.input.map({ Data($0.utf8) == frozen.input.map { Data($0.utf8) } }) != false,
              selected.visibleResult.map({ Data($0.utf8) == frozen.visibleResult.map { Data($0.utf8) } }) != false,
              selected.resultKind == (selected.visibleResult == nil ? nil : frozen.resultKind),
              selected.resultWasPartial == (selected.visibleResult == nil ? nil : frozen.resultWasPartial),
              selected.resultCapturedAt == (selected.visibleResult == nil ? nil : frozen.resultCapturedAt),
              try TaskMaterialFormat.encoder().encode(selected.successfulCheckpoint) == TaskMaterialFormat.encoder().encode(selected.successfulCheckpoint == nil ? nil : frozen.successfulCheckpoint) else { throw TaskMaterialError.changed }
        guard makeSessionRoom(additionalBytes: selected.rawBytes) else { throw TaskMaterialError.capacity }
        try buffer.claimSave()
        let id = UUID(), permission = taskMaterialFence.current
        taskMaterialWriteReservations[id] = selected.rawBytes
        let operation = Task { @MainActor [self] () throws -> TaskMaterialHandle in
            defer { taskMaterialSaveOperations[id] = nil; taskMaterialWriteReservations[id] = nil }
            guard try await materialOwnerExists(buffer.key), !buffer.invalidated, taskMaterialFence.current == permission else { throw TaskMaterialError.staleCheck }
            let check = try await taskMaterialStore.prepareWrite(buffer.key, expected: expected)
            guard !isShuttingDown, !isClearingHistory, !buffer.invalidated, taskMaterialFence.current == permission,
                  try await materialOwnerExists(buffer.key) else { throw TaskMaterialError.staleCheck }
            guard !buffer.invalidated, taskMaterialFence.current == permission, !Task.isCancelled else { throw TaskMaterialError.staleCheck }
            let handle = try await taskMaterialStore.save(selected, using: check)
            let ownerStillExists = try await materialOwnerExists(buffer.key)
            if ownerStillExists, !isShuttingDown, !isClearingHistory, !taskMaterialClearing,
               taskMaterialFence.current == permission { taskMaterialHandles[buffer.key] = handle }
            return handle
        }
        taskMaterialSaveOperations[id] = operation
        // 已确认保存的真实写入收口独立于sheet取消，停用/清除通过同步Fence撤销未提交写入。
        return operation
    }

    func refreshTaskMaterialIndex() async {
        let request = UUID(); taskMaterialIndexRequest = request
        do {
            let inventory = try await taskMaterialStore.inventory()
            let generation = taskMaterialFence.current.generation
            let owners = inventory.handles.isEmpty ? Set<TaskMaterialKey>() : try await taskMaterialOwners()
            let cli = inventory.handles.isEmpty ? [] : await invocationStore.list()
            let ai = inventory.handles.isEmpty ? [] : await aiInvocationStore.list()
            let receipts = Dictionary(uniqueKeysWithValues: cli.compactMap { receipt in materialKey(receipt, .cli).map { ($0, receipt) } } + ai.compactMap { receipt in materialKey(receipt, .ai).map { ($0, receipt) } })
            guard !isShuttingDown, !isClearingHistory, !taskMaterialClearing,
                  request == taskMaterialIndexRequest, inventory.generation == generation,
                  generation == taskMaterialFence.current.generation else { return }
            let display = inventory.handles.filter { owners.contains($0.key) && $0.header.expiresAt > Date().timeIntervalSince1970 }
                .sorted { $0.header.createdAt > $1.header.createdAt }.prefix(200)
            taskMaterialHandles = Dictionary(uniqueKeysWithValues: display.map { ($0.key, $0) })
            taskMaterialRecords = taskMaterialHandles.values.compactMap { handle in
                guard let receipt = receipts[handle.key] else { return nil }
                let titleKey = handle.key.receiptStore == .ai ? AITaskReceiptKind(rawValue: receipt.name)?.rawValue : nil
                let title = TaskTextLimits.prefix(receipt.name, maximumBytes: 1_024)
                return TaskMaterialListRecord(handle: handle, title: title, titleKey: titleKey, isTerminal: receipt.state.isTerminal)
            }.sorted { $0.handle.header.createdAt > $1.handle.header.createdAt }
            if !inventory.isComplete || inventory.handles.count > 200 { taskMaterialNotice = noticeKey("Some retained task content needs attention. Existing files were kept; review or clear it in Privacy settings.") }
        } catch { if !isShuttingDown, request == taskMaterialIndexRequest { taskMaterialNotice = taskMaterialErrorNotice(error) } }
    }
    func taskMaterialOwners() async throws -> Set<TaskMaterialKey> {
        let cli = try await invocationStore.materialOwners(), ai = try await aiInvocationStore.materialOwners()
        func keys(_ values: [RunMaterialOwner], _ namespace: TaskMaterialKey.ReceiptStore) -> [TaskMaterialKey] {
            values.map { .init(receiptStore: namespace, invocationID: $0.invocationID, receiptRecordIdentity: $0.recordIdentity) }
        }
        return Set(keys(cli, .cli) + keys(ai, .ai))
    }
    func materialKey(_ receipt: InvocationReceipt, _ namespace: TaskMaterialKey.ReceiptStore) -> TaskMaterialKey? {
        receipt.runAttempt.map { .init(receiptStore: namespace, invocationID: receipt.id, receiptRecordIdentity: $0.recordIdentity) }
    }
    func taskMaterialErrorNotice(_ error: Error) -> LocalizedNotice {
        switch error {
        case TaskMaterialError.capacity: noticeKey("Task content is at its text or storage limit. Clear older content or close a review, then try again.")
        case TaskMaterialError.durabilityUncertain: noticeKey("Saving could not be confirmed. Inspect retained content before saving again.")
        case TaskMaterialError.permissionDenied: noticeKey("Task content retention is off. Existing saved content can still be viewed or deleted.")
        default: noticeKey("Task content is unavailable or changed. Review it again; nothing was executed or copied.")
        }
    }
}
