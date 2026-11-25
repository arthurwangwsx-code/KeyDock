import Foundation
import AutomationCore
import ExecutionCore

struct TaskMaterialCaptureSnapshot: Sendable {
    let key: TaskMaterialKey
    let input: String?
    let successfulCheckpoint: TaskMaterialCheckpoint?
    let latestBoundaryExceededLimit: Bool
}

/// 运行入口创建的临时正文槽；同步成功端口不依赖MainActor异步发布的顺序。
/// 不Codable，不持有执行grant，也不向磁盘写入任何内容。
final class TaskMaterialCapture: @unchecked Sendable {
    static let checkpointReservation = TaskMaterialLimits.inputBytes + TaskMaterialLimits.outputBytes
    let id = UUID()
    let runID: UUID
    let definition: RunDefinitionReference
    private let fence: TaskMaterialFence
    private let permission: TaskMaterialFence.Snapshot
    private let lock = NSLock()
    private var input: String?
    private var key: TaskMaterialKey?
    private var checkpoint: TaskMaterialCheckpoint?
    private var lastSequence = -1
    private var boundaryExceededLimit = false
    private var finished = false
    private var revoked = false

    init?(runID: UUID, definition: RunDefinitionReference, input: String?, fence: TaskMaterialFence) {
        let permission = fence.current
        guard permission.enabled, definition.isValid,
              (definition.kind == .savedCommand ? input == nil : input != nil),
              (input?.utf8.count ?? 0) <= TaskMaterialLimits.inputBytes else { return nil }
        self.runID = runID; self.definition = definition; self.input = input
        self.fence = fence; self.permission = permission
    }

    /// 只绑定已成功begin的本worker；不可把相同run UUID重绑到另一次出生。
    func bind(_ begun: InvocationBeginReceipt, namespace: TaskMaterialKey.ReceiptStore) {
        lock.withLock {
            guard valid, key == nil, let metadata = begun.receipt.runAttempt, let stamp = begun.runStamp,
                  begun.receipt.id == runID, stamp.invocationID == runID,
                  stamp.recordIdentity == metadata.recordIdentity, metadata.definition == definition,
                  (namespace == .cli) == (definition.kind == .savedCommand) else { return }
            key = .init(receiptStore: namespace, invocationID: runID, receiptRecordIdentity: metadata.recordIdentity)
        }
    }

    func observe(_ material: WorkflowSuccessfulMaterial) {
        lock.withLock {
            guard valid, !finished, key != nil, definition.kind == .workflow,
                  material.runID == runID, material.definitionID == definition.definitionID,
                  material.definitionVersion == definition.definitionVersion,
                  (0..<1_024).contains(material.stepIndex), (0..<4_096).contains(material.sequence),
                  material.sequence > lastSequence else { return }
            lastSequence = material.sequence
            // 新成功边界若过大，不能把更早一步冒充为“最近成功步骤”。不截断正文。
            guard material.input.utf8.count <= TaskMaterialLimits.inputBytes,
                  material.output.utf8.count <= TaskMaterialLimits.outputBytes else {
                checkpoint = nil; boundaryExceededLimit = true; return
            }
            checkpoint = .init(runID: material.runID, definitionID: material.definitionID,
                definitionVersion: material.definitionVersion, stepID: material.stepID,
                stepIndex: material.stepIndex, sequence: material.sequence, input: material.input, output: material.output)
            boundaryExceededLimit = false
        }
    }

    func snapshot() -> TaskMaterialCaptureSnapshot? {
        lock.withLock {
            guard valid, let key else { return nil }
            return .init(key: key, input: input, successfulCheckpoint: checkpoint,
                         latestBoundaryExceededLimit: boundaryExceededLimit)
        }
    }

    var budgetedBytes: Int {
        lock.withLock {
            guard !revoked else { return 0 }
            return (input?.utf8.count ?? 0) +
                (definition.kind == .workflow && !finished ? Self.checkpointReservation : checkpointBytes)
        }
    }
    var capturedInputBytes: Int { lock.withLock { input?.utf8.count ?? 0 } }
    func finish() { lock.withLock { finished = true } }
    func revoke() {
        lock.withLock { revoked = true; finished = true; input = nil; checkpoint = nil; key = nil }
    }
    private var valid: Bool {
        let current = fence.current
        return !revoked && current.enabled && permission.permissionEpoch == current.permissionEpoch
    }
    private var checkpointBytes: Int { checkpoint.map { $0.input.utf8.count + $0.output.utf8.count } ?? 0 }
}
