import Foundation

/// 只定位保存的定义；不是授权，也不包含可执行配置、输入或输出。
public enum RecoverableRunKind: String, Codable, Sendable {
    case savedCommand, aiAction, agent, workflow
}

public struct RunDefinitionReference: Codable, Equatable, Sendable {
    public let kind: RecoverableRunKind
    public let definitionID: UUID
    public let definitionVersion: Int?
    public let fingerprint: String
    public init(kind: RecoverableRunKind, definitionID: UUID, definitionVersion: Int? = nil, fingerprint: String) {
        self.kind = kind; self.definitionID = definitionID; self.definitionVersion = definitionVersion; self.fingerprint = fingerprint
    }
    public var isValid: Bool {
        fingerprint.utf8.count == 64 && fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        definitionVersion.map { $0 > 0 } != false
    }
}

public struct RunAttemptMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    /// 与receipt.id不同的出生身份，拒绝删除后重建同UUID的旧检查。
    public let recordIdentity: UUID
    public let logicalRunID: UUID
    public let recoveryOf: UUID?
    public let definition: RunDefinitionReference
    public internal(set) var revision: UInt64
    public init(logicalRunID: UUID, recoveryOf: UUID? = nil, definition: RunDefinitionReference,
                schemaVersion: Int = 1, recordIdentity: UUID = UUID(), revision: UInt64 = 1) {
        self.schemaVersion = schemaVersion; self.recordIdentity = recordIdentity; self.logicalRunID = logicalRunID
        self.recoveryOf = recoveryOf; self.definition = definition; self.revision = revision
    }
    public func isValid(for receiptID: UUID) -> Bool {
        schemaVersion == 1 && revision > 0 && definition.isValid && recoveryOf != receiptID &&
        (recoveryOf == nil ? logicalRunID == receiptID : logicalRunID != receiptID)
    }
}

/// 只在当前actor实例有效，不能Codable或从历史反序列化；不是执行grant。
public struct RunRecoveryCheck: Sendable {
    public let receipt: InvocationReceipt
    let storeIdentity: UUID
    init(receipt: InvocationReceipt, storeIdentity: UUID) { self.receipt = receipt; self.storeIdentity = storeIdentity }
}

/// 当前worker的条件写入身份；出生身份与actor实例均须匹配，不能仅比较revision数字。
public struct RunAttemptStamp: Sendable {
    public let invocationID: UUID
    public let recordIdentity: UUID
    public let revision: UInt64
    let storeIdentity: UUID
    init(invocationID: UUID, metadata: RunAttemptMetadata, storeIdentity: UUID) {
        self.invocationID = invocationID; recordIdentity = metadata.recordIdentity
        revision = metadata.revision; self.storeIdentity = storeIdentity
    }
}

public struct InvocationBeginReceipt: Sendable {
    public let receipt: InvocationReceipt
    public let runStamp: RunAttemptStamp?
}

/// intent可能已rename但begin未成功返回；此身份仅用于收口，不能据此派发。
public struct InvocationBeginFailure: Error, Sendable {
    public let cause: InvocationStoreError
    public let undispatchedStamp: RunAttemptStamp
}

public struct LogicalRunRecord: Identifiable, Sendable {
    public let id: UUID
    public let attempts: [InvocationReceipt]
    public let hasMissingAncestors: Bool
    public let hasLiveAttempts: Bool
}

public struct RunStoreSnapshot: Sendable {
    public let logicalRuns: [LogicalRunRecord]
    public let legacyReceipts: [InvocationReceipt]
}

/// 与副作用回执共用同一文件和预算，校验是线性的，不递归跟随无界恢复链。
enum RunAttemptValidation {
    static func validate(_ receipts: [UUID: InvocationReceipt]) throws {
        for receipt in receipts.values {
            guard let metadata = receipt.runAttempt else { continue }
            guard metadata.isValid(for: receipt.id) else { throw InvocationStoreError.invalidMetadata }
            if let parentID = metadata.recoveryOf, let parent = receipts[parentID] {
                guard let origin = parent.runAttempt, origin.logicalRunID == metadata.logicalRunID,
                      origin.definition.kind == metadata.definition.kind,
                      origin.definition.definitionID == metadata.definition.definitionID else { throw InvocationStoreError.invalidMetadata }
            }
        }
        var finished: Set<UUID> = []
        for id in receipts.keys where receipts[id]?.runAttempt != nil && !finished.contains(id) {
            var path: Set<UUID> = [], cursor: UUID? = id
            while let current = cursor, !finished.contains(current), let metadata = receipts[current]?.runAttempt {
                guard path.insert(current).inserted else { throw InvocationStoreError.invalidMetadata }
                cursor = metadata.recoveryOf
            }
            finished.formUnion(path)
        }
    }
}

/// 仅供持久化故障注入；默认不注入，所有路径仍执行真实原子写入。
public enum InvocationPersistencePoint: Sendable, Equatable { case beforeWrite, beforeRename, afterRename }
