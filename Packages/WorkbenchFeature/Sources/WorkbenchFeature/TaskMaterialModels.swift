import Foundation
import CryptoKit

/// 稳定出生身份；不包含执行权限、actor身份或来源的可变revision。
struct TaskMaterialKey: Codable, Hashable, Sendable {
    enum ReceiptStore: String, Codable, Hashable, Sendable { case cli, ai }
    let receiptStore: ReceiptStore
    let invocationID: UUID
    let receiptRecordIdentity: UUID
    var fileName: String {
        "\(receiptStore.rawValue)-\(invocationID.uuidString.lowercased())-\(receiptRecordIdentity.uuidString.lowercased()).kdmaterial"
    }
    static func fromFileName(_ name: String) -> Self? {
        guard name.hasSuffix(".kdmaterial") else { return nil }
        let stem = String(name.dropLast(".kdmaterial".count))
        guard let separator = stem.firstIndex(of: "-"), let store = ReceiptStore(rawValue: String(stem[..<separator])) else { return nil }
        let tail = String(stem[stem.index(after: separator)...])
        guard tail.utf8.count == 73,
              tail.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || $0 == 45 }),
              tail[tail.index(tail.startIndex, offsetBy: 36)] == "-",
              let invocation = UUID(uuidString: String(tail.prefix(36))),
              let birth = UUID(uuidString: String(tail.suffix(36))) else { return nil }
        let key = Self(receiptStore: store, invocationID: invocation, receiptRecordIdentity: birth)
        return key.fileName == name ? key : nil
    }
}

enum TaskMaterialField: String, Codable, CaseIterable, Hashable, Sendable { case input, visibleResult, successfulCheckpoint }
enum TaskMaterialResultKind: String, Codable, Equatable, Sendable { case visibleResult, agentIncludingToolReturns }

struct TaskMaterialCheckpoint: Codable, Sendable {
    let runID: UUID
    let definitionID: UUID
    let definitionVersion: Int
    let stepID: UUID
    let stepIndex: Int
    let sequence: Int
    let input: String
    let output: String
}

/// 仅保存用户逐项选中的内容，不从执行定义或授权对象自动编码。
struct SelectedTaskMaterial: Codable, Sendable {
    var input: String?
    var visibleResult: String?
    var resultKind: TaskMaterialResultKind?
    var resultWasPartial: Bool?
    var resultCapturedAt: TimeInterval?
    var successfulCheckpoint: TaskMaterialCheckpoint?
    var fields: [TaskMaterialField] {
        TaskMaterialField.allCases.filter {
            switch $0 {
            case .input: input != nil
            case .visibleResult: visibleResult != nil
            case .successfulCheckpoint: successfulCheckpoint != nil
            }
        }
    }
    var rawBytes: Int {
        (input?.utf8.count ?? 0) + (visibleResult?.utf8.count ?? 0) +
        (successfulCheckpoint.map { $0.input.utf8.count + $0.output.utf8.count } ?? 0)
    }
    func validate(for key: TaskMaterialKey) throws {
        guard !fields.isEmpty, (visibleResult == nil) == (resultKind == nil),
              (visibleResult == nil) == (resultWasPartial == nil), (visibleResult == nil) == (resultCapturedAt == nil),
              resultCapturedAt.map({ $0.isFinite && $0 >= 0 }) != false,
              (input?.utf8.count ?? 0) <= TaskMaterialLimits.inputBytes,
              (visibleResult?.utf8.count ?? 0) <= TaskMaterialLimits.outputBytes else { throw TaskMaterialError.invalidContent }
        if key.receiptStore == .cli, input != nil || successfulCheckpoint != nil { throw TaskMaterialError.invalidContent }
        if let checkpoint = successfulCheckpoint {
            guard checkpoint.runID == key.invocationID, checkpoint.definitionVersion > 0,
                  (0..<1_024).contains(checkpoint.stepIndex), (0..<4_096).contains(checkpoint.sequence),
                  checkpoint.input.utf8.count <= TaskMaterialLimits.inputBytes,
                  checkpoint.output.utf8.count <= TaskMaterialLimits.outputBytes else { throw TaskMaterialError.invalidContent }
        }
    }
}

enum TaskMaterialLimits {
    static let inputBytes = 128 * 1_024
    static let outputBytes = 1_024 * 1_024
    static let headerBytes = 8 * 1_024
    static let recordBytes = 4 * 1_024 * 1_024
    static let controlBytes = 64 * 1_024
    static let enumerationCount = 2_048
}

struct TaskMaterialPolicy: Sendable {
    var retentionInterval: TimeInterval = 7 * 86_400
    var maximumCount = 200
    var maximumTotalBytes = 64 * 1_024 * 1_024
    var maximumRecordBytes = TaskMaterialLimits.recordBytes
    func validate() throws {
        guard retentionInterval.isFinite, retentionInterval > 0, retentionInterval <= 7 * 86_400,
              (1...200).contains(maximumCount), (1...64 * 1_024 * 1_024).contains(maximumTotalBytes),
              (128...TaskMaterialLimits.recordBytes).contains(maximumRecordBytes) else { throw TaskMaterialError.invalidPolicy }
    }
}

struct TaskMaterialVersion: Codable, Equatable, Sendable {
    let identity: UUID
    let revision: UInt64
}

struct TaskMaterialHeader: Codable, Sendable {
    let formatVersion: Int
    let key: TaskMaterialKey
    let version: TaskMaterialVersion
    let createdAt: TimeInterval
    let expiresAt: TimeInterval
    let fields: [TaskMaterialField]
    let resultKind: TaskMaterialResultKind?
    let resultWasPartial: Bool?
    let resultCapturedAt: TimeInterval?
    let rawBytes: Int
    let payloadBytes: Int
    let payloadSHA256: String
    func validate() throws {
        guard formatVersion == 1, version.revision > 0,
              createdAt.isFinite, expiresAt.isFinite, createdAt >= 0, expiresAt >= createdAt,
              expiresAt - createdAt <= 7 * 86_400,
              !fields.isEmpty, Set(fields).count == fields.count,
              fields.contains(.visibleResult) == (resultKind != nil),
              fields.contains(.visibleResult) == (resultWasPartial != nil), fields.contains(.visibleResult) == (resultCapturedAt != nil),
              resultCapturedAt.map({ $0.isFinite && $0 >= 0 }) != false,
              rawBytes >= 0, rawBytes <= 2 * (TaskMaterialLimits.inputBytes + TaskMaterialLimits.outputBytes),
              (2...TaskMaterialLimits.recordBytes).contains(payloadBytes),
              payloadSHA256.utf8.count == 64,
              payloadSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TaskMaterialError.invalidHeader
        }
        if key.receiptStore == .cli, fields != [.visibleResult] || resultKind != .visibleResult { throw TaskMaterialError.invalidHeader }
    }
}

enum TaskMaterialError: Error, Equatable, Sendable {
    case invalidPolicy, invalidContent, invalidHeader, unsupportedFormat, invalidClock
    case unavailable, busy, closed, unsafeEntry, changed, missing, capacity, malformedControl, expired
    case staleCheck, foreignCheck, permissionDenied, pendingDeletion, recoveryRequired, revisionExhausted
    case io(Int32), durabilityUncertain(Int32)
}

enum TaskMaterialPersistencePoint: Equatable, Sendable { case beforeFileSync, beforeRename, afterRename, beforeDirectorySync, beforeDelete }
enum TaskMaterialWriteRole: Equatable, Sendable { case body, control }

/// 文件身份只在当前进程使用，不序列化到材料中。
struct TaskMaterialFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let mode: UInt16
}

struct TaskMaterialHandle: Sendable {
    let header: TaskMaterialHeader
    let fileIdentity: TaskMaterialFileIdentity
    let headerSHA256: String
    var key: TaskMaterialKey { header.key }
    var version: TaskMaterialVersion { header.version }
}

struct TaskMaterialInventory: Sendable {
    var handles: [TaskMaterialHandle] = []
    var retainedBytes = 0
    var managedTemporaryNames: [String] = []
    var unsafeNames: [String] = []
    var pendingDeletion = false
    var pendingWrite = false
    var generation: UUID?
    var isComplete: Bool { unsafeNames.isEmpty && managedTemporaryNames.isEmpty && !pendingDeletion && !pendingWrite }
}

struct TaskMaterialMutationReport: Sendable {
    var removedNames: Set<String> = []
    var remainingNames: Set<String> = []
    var failedNames: Set<String> = []
    var pendingDeletion = false
    var didInspectRemaining = false
    var failure: TaskMaterialError?
    var isComplete: Bool { failure == nil && failedNames.isEmpty && remainingNames.isEmpty && !pendingDeletion }
}

/// 主线程撤权无需等待actor；此对象不授予执行权限。
final class TaskMaterialFence: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable { let permissionEpoch: UUID; let generation: UUID; let enabled: Bool }
    private let lock = NSLock()
    private var permissionEpoch = UUID()
    private var generation = UUID()
    private var enabled = false
    var current: Snapshot { lock.withLock { .init(permissionEpoch: permissionEpoch, generation: generation, enabled: enabled) } }
    @discardableResult func setEnabled(_ value: Bool) -> Snapshot {
        lock.withLock {
            permissionEpoch = UUID(); generation = UUID(); enabled = value
            return .init(permissionEpoch: permissionEpoch, generation: generation, enabled: enabled)
        }
    }
    @discardableResult func invalidateContent() -> Snapshot {
        lock.withLock {
            generation = UUID()
            return .init(permissionEpoch: permissionEpoch, generation: generation, enabled: enabled)
        }
    }
    /// 只包住最后的metadata rename；撤权与提交有明确先后，不把编码／fsync放进主线程等待的锁。
    func commit(if expected: Snapshot, _ operation: () throws -> Void) throws {
        try lock.withLock {
            guard enabled, permissionEpoch == expected.permissionEpoch, generation == expected.generation else { throw TaskMaterialError.permissionDenied }
            try operation()
        }
    }
}

struct TaskMaterialWriteCheck: Equatable, Sendable {
    let key: TaskMaterialKey
    let expected: TaskMaterialVersion?
    let storeIdentity: UUID
    let nonce: UUID
    let fence: TaskMaterialFence.Snapshot
}

enum TaskMaterialFormat {
    static let magic = Data("KDMAT001".utf8)
    static let prefixBytes = 12
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    static func frame(_ material: SelectedTaskMaterial, key: TaskMaterialKey, version: TaskMaterialVersion,
                      createdAt: TimeInterval, expiresAt: TimeInterval) throws -> (Data, TaskMaterialHeader) {
        try material.validate(for: key)
        let payload = try encoder().encode(material)
        guard payload.count <= TaskMaterialLimits.recordBytes else { throw TaskMaterialError.capacity }
        let header = TaskMaterialHeader(formatVersion: 1, key: key, version: version, createdAt: createdAt, expiresAt: expiresAt,
            fields: material.fields, resultKind: material.resultKind,
            resultWasPartial: material.resultWasPartial, resultCapturedAt: material.resultCapturedAt, rawBytes: material.rawBytes,
            payloadBytes: payload.count, payloadSHA256: digest(payload))
        try header.validate()
        let bytes = try encoder().encode(header)
        guard bytes.count <= TaskMaterialLimits.headerBytes, prefixBytes + bytes.count + payload.count <= TaskMaterialLimits.recordBytes else {
            throw TaskMaterialError.capacity
        }
        let count = UInt32(bytes.count)
        var frame = magic
        frame.append(contentsOf: [UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        frame.append(bytes); frame.append(payload)
        return (frame, header)
    }
    static func headerLength(_ prefix: Data) throws -> Int {
        guard prefix.count == prefixBytes, prefix.prefix(8) == magic else { throw TaskMaterialError.unsupportedFormat }
        let count = prefix.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard (2...TaskMaterialLimits.headerBytes).contains(count) else { throw TaskMaterialError.invalidHeader }
        return count
    }
    static func decodeHeader(_ bytes: Data, fileBytes: Int, headerBytes: Int) throws -> TaskMaterialHeader {
        let object = try requireKeys(bytes, allowed: ["formatVersion", "key", "version", "createdAt", "expiresAt", "fields", "resultKind", "resultWasPartial", "resultCapturedAt", "rawBytes", "payloadBytes", "payloadSHA256"], required: ["formatVersion", "key", "version", "createdAt", "expiresAt", "fields", "rawBytes", "payloadBytes", "payloadSHA256"])
        try requireObjectKeys(object["key"], keys: ["receiptStore", "invocationID", "receiptRecordIdentity"])
        try requireObjectKeys(object["version"], keys: ["identity", "revision"])
        let header = try JSONDecoder().decode(TaskMaterialHeader.self, from: bytes)
        try header.validate()
        guard fileBytes <= TaskMaterialLimits.recordBytes, fileBytes == prefixBytes + headerBytes + header.payloadBytes else { throw TaskMaterialError.invalidHeader }
        return header
    }
    static func decodePayload(_ bytes: Data, header: TaskMaterialHeader) throws -> SelectedTaskMaterial {
        guard bytes.count == header.payloadBytes, digest(bytes) == header.payloadSHA256 else { throw TaskMaterialError.changed }
        let object = try requireKeys(bytes, allowed: ["input", "visibleResult", "resultKind", "resultWasPartial", "resultCapturedAt", "successfulCheckpoint"], required: [])
        if let checkpoint = object["successfulCheckpoint"], !(checkpoint is NSNull) {
            try requireObjectKeys(checkpoint, keys: ["runID", "definitionID", "definitionVersion", "stepID", "stepIndex", "sequence", "input", "output"])
        }
        let payload = try JSONDecoder().decode(SelectedTaskMaterial.self, from: bytes)
        try payload.validate(for: header.key)
        guard payload.fields == header.fields, payload.resultKind == header.resultKind,
              payload.resultWasPartial == header.resultWasPartial, payload.resultCapturedAt == header.resultCapturedAt,
              payload.rawBytes == header.rawBytes else { throw TaskMaterialError.invalidContent }
        return payload
    }
    private static func requireKeys(_ bytes: Data, allowed: Set<String>, required: Set<String>) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else { throw TaskMaterialError.unsupportedFormat }
        return object
    }
    private static func requireObjectKeys(_ value: Any?, keys: Set<String>) throws {
        guard let object = value as? [String: Any], Set(object.keys) == keys else { throw TaskMaterialError.unsupportedFormat }
    }
}
