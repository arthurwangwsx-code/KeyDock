import Darwin
import Foundation

public struct InvocationReceipt: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var state: ExecutionState
    public let startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var message: String
    public var commandID: String?
    public var commandVersion: Int?
    public var configurationFingerprint: String?
    public var caller: String?

    public init(id: UUID, name: String, state: ExecutionState, startedAt: Date = Date(), finishedAt: Date? = nil, exitCode: Int32? = nil, message: String = "", commandID: String? = nil, commandVersion: Int? = nil, configurationFingerprint: String? = nil, caller: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.message = message
        self.commandID = commandID; self.commandVersion = commandVersion
        self.configurationFingerprint = configurationFingerprint; self.caller = caller
    }
}

public enum InvocationStoreError: Error, Sendable {
    case invalidDirectory, unsupportedVersion, duplicateInvocation, missingInvocation, nonterminalResult, io(Int32)
}

/// 只记录最小元数据；不保存命令参数、环境、stdout/stderr，也不重放任何任务。
public actor InvocationStore {
    private struct Envelope: Codable {
        let version: Int
        let receipts: [InvocationReceipt]
    }
    private let fileURL: URL
    private var receipts: [UUID: InvocationReceipt]

    public init(directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InvocationStoreError.invalidDirectory
        }
        guard chmod(directory.path, 0o700) == 0 else { throw InvocationStoreError.io(errno) }
        let target = directory.appendingPathComponent("invocations.json")
        var values: [UUID: InvocationReceipt] = [:]
        if manager.fileExists(atPath: target.path) {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: target))
            guard envelope.version == 1 else { throw InvocationStoreError.unsupportedVersion }
            for var receipt in envelope.receipts {
                guard values[receipt.id] == nil else { throw InvocationStoreError.duplicateInvocation }
                if receipt.state == .running || receipt.state == .queued {
                    receipt.state = .interrupted
                    receipt.finishedAt = Date()
                    receipt.exitCode = nil
                    receipt.message = receipt.message == "terminal.handoffIntent" ? "terminal.handoffUnknown" : "process.interrupted.unknown"
                }
                values[receipt.id] = receipt
            }
        }
        self.fileURL = target
        self.receipts = values
        try Self.persist(values, to: target)
    }

    public func begin(id: UUID, name: String, commandID: String? = nil, commandVersion: Int? = nil, configurationFingerprint: String? = nil, caller: String? = nil, initialMessage: String = "") throws {
        guard receipts[id] == nil else { throw InvocationStoreError.duplicateInvocation }
        var next = receipts
        next[id] = .init(id: id, name: String(name.prefix(256)), state: .running, message: initialMessage, commandID: commandID, commandVersion: commandVersion, configurationFingerprint: configurationFingerprint, caller: caller)
        try Self.persist(next, to: fileURL)
        receipts = next
    }

    public func finish(id: UUID, result: ProcessResult) throws {
        guard var receipt = receipts[id] else { throw InvocationStoreError.missingInvocation }
        guard result.state.isTerminal else { throw InvocationStoreError.nonterminalResult }
        // 迟到的输出/完成事件不得覆盖取消或重启后的 interrupted 终态。
        guard !receipt.state.isTerminal else { return }
        receipt.state = result.state
        receipt.finishedAt = Date()
        receipt.exitCode = result.exitCode
        receipt.message = result.message
        var next = receipts
        next[id] = receipt
        try Self.persist(next, to: fileURL)
        receipts = next
    }

    public func list() -> [InvocationReceipt] {
        receipts.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func persist(_ receipts: [UUID: InvocationReceipt], to fileURL: URL) throws {
        let envelope = Envelope(version: 1, receipts: receipts.values.sorted { $0.id.uuidString < $1.id.uuidString })
        let data = try JSONEncoder().encode(envelope)
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".invocations-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw InvocationStoreError.io(errno) }
        var closed = false
        defer {
            if !closed { Darwin.close(fd) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var position = 0
            while position < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: position), buffer.count - position)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw InvocationStoreError.io(errno) }
                position += count
            }
        }
        guard fsync(fd) == 0 else { throw InvocationStoreError.io(errno) }
        guard Darwin.close(fd) == 0 else { closed = true; throw InvocationStoreError.io(errno) }
        closed = true
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw InvocationStoreError.io(errno) }
        let directoryFD = Darwin.open(fileURL.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 {
            defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw InvocationStoreError.io(errno) }
        }
    }
}
