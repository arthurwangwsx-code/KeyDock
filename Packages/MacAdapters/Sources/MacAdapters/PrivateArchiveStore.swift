import Foundation
import Darwin

public enum ArchiveStoreError: Error, Equatable { case unavailable, externalChange, rollbackIncomplete }

/// 只用于故障注入；不能替换底层writer或绕过提交算法。
public enum ArchiveStoreFaultStage: String, Sendable {
    case beforeCandidateWrite, afterCandidateFileSync, beforeCommit, afterCommit
    case beforeCommitDirectorySync, afterCommitDirectorySync
    case beforeCompensation, afterCompensation, beforeCompensationDirectorySync
}

/// 固定目录fd的单owner动作档案。未知外部内容保留并停写，不自动恢复或重放。
@MainActor final class PrivateArchiveStore<Value> {
    private(set) var value: Value
    private(set) var writable = true
    /// 仅basename，供本地人工恢复；不含正文，不自动删除未知文件。
    private(set) var preservedFiles: [String] = []
    private(set) var recoveryFilesMayBeTruncated = false
    private let fileName: String
    private let transactionPrefix: String
    private let maximumBytes: Int
    private let encode: (Value) throws -> Data
    private let directory: URL
    private let directoryFD: Int32
    private let directoryIdentity: Identity
    private let faultHook: @MainActor (ArchiveStoreFaultStage) throws -> Void
    private var known: Snapshot?
    private var saving = false

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino
            kind = value.st_mode & mode_t(S_IFMT)
        }
    }
    private struct Snapshot: Equatable {
        let identity: Identity
        let bytes: Data
    }

    init(directory: URL, fileName: String, transactionPrefix: String, maximumBytes: Int,
         empty: Value, decode: (Data) throws -> Value, encode: @escaping (Value) throws -> Data,
         faultHook: @escaping @MainActor (ArchiveStoreFaultStage) throws -> Void = { _ in }) throws {
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/"), !fileName.contains("\0"),
              transactionPrefix.hasPrefix("."), !transactionPrefix.contains("/"), !transactionPrefix.contains("\0"),
              (1...67_108_864).contains(maximumBytes) else { throw ArchiveStoreError.unavailable }
        guard directory.isFileURL else { throw ArchiveStoreError.unavailable }
        let location = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(location.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveStoreError.unavailable }
        var adopted = false
        defer { if !adopted { Darwin.close(fd) } }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(), fchmod(fd, mode_t(0o700)) == 0 else {
            throw ArchiveStoreError.unavailable
        }
        let identity = Identity(metadata)
        try Self.requireDirectory(location, identity: identity)
        let pending = try Self.recoveryNames(fd, transactionPrefix: transactionPrefix)
        // 残留只列文件名；不读取残留或final正文，不把未确认的配置重新接入动作目录。
        let initial = pending.names.isEmpty ? try Self.read(fd, name: fileName, maximumBytes: maximumBytes) : nil
        let initialValue = try initial.map { try decode($0.bytes) } ?? empty
        let finalExists: Bool
        if pending.names.isEmpty { finalExists = false }
        else { finalExists = try Self.identityAt(fd, name: fileName) != nil }
        try Self.requireDirectory(location, identity: identity)
        self.directory = location; self.directoryFD = fd; self.directoryIdentity = identity
        self.faultHook = faultHook; self.known = initial; self.value = initialValue
        self.fileName = fileName; self.transactionPrefix = transactionPrefix
        self.maximumBytes = maximumBytes; self.encode = encode
        if !pending.names.isEmpty {
            self.writable = false; self.preservedFiles = pending.names
            self.recoveryFilesMayBeTruncated = pending.mayBeTruncated
            if finalExists { self.preservedFiles.append(fileName) }
        }
        adopted = true
    }

    deinit { Darwin.close(directoryFD) }

    /// 无变化保存也必须核对当前磁盘／目录；不创建候选，不递增业务修订。
    func validateCurrent() throws {
        guard writable, !saving else { throw ArchiveStoreError.unavailable }
        try validateStoredSnapshot()
    }

    private func validateStoredSnapshot() throws {
        do {
            try validateDirectory()
            guard try Self.read(directoryFD, name: fileName, maximumBytes: maximumBytes) == known else { throw ArchiveStoreError.externalChange }
        } catch { writable = false; throw error }
    }

    func save(_ next: Value) throws {
        guard writable, !saving else { throw ArchiveStoreError.unavailable }
        saving = true; defer { saving = false }
        let encoded = try encode(next)
        guard encoded.count <= maximumBytes else { throw ArchiveStoreError.unavailable }
        try validateStoredSnapshot()

        let previous = known
        let temporary = transactionPrefix + UUID().uuidString
        var candidate: Snapshot?
        var creationAttempted = false
        var committed = false
        var conflict = false
        do {
            try faultHook(.beforeCandidateWrite)
            creationAttempted = true
            try Self.writeCandidate(directoryFD, name: temporary, bytes: encoded, proof: &candidate, maximumBytes: maximumBytes)
            try faultHook(.afterCandidateFileSync)
            try validateDirectory()
            guard try Self.read(directoryFD, name: fileName, maximumBytes: maximumBytes) == previous else {
                conflict = true; throw ArchiveStoreError.externalChange
            }
            try faultHook(.beforeCommit)
            try validateDirectory()
            let flags = previous == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
            guard renameatx_np(directoryFD, temporary, directoryFD, fileName, flags) == 0 else {
                if errno == EEXIST || errno == ENOENT { conflict = true }
                throw conflict ? ArchiveStoreError.externalChange : ArchiveStoreError.unavailable
            }
            committed = true
            try faultHook(.afterCommit)
            try validateDirectory()
            try verifyCommitted(candidate: candidate, previous: previous, temporary: temporary)
            try faultHook(.beforeCommitDirectorySync)
            try syncDirectory()
            try faultHook(.afterCommitDirectorySync)
            try validateDirectory()
            try verifyCommitted(candidate: candidate, previous: previous, temporary: temporary)
        } catch {
            if !directoryStillMatches() { conflict = true }
            if !committed {
                do { if try Self.read(directoryFD, name: fileName, maximumBytes: maximumBytes) != previous { conflict = true } }
                catch { conflict = true }
            }
            if committed, let candidate {
                do {
                    guard try compensate(candidate: candidate, previous: previous,
                                         temporary: temporary, conflict: &conflict) else {
                        throw ArchiveStoreError.rollbackIncomplete
                    }
                } catch {
                    writable = false; preserveExisting(temporary); preserveExisting(fileName)
                    throw ArchiveStoreError.rollbackIncomplete
                }
            } else if let candidate, !removeKnown(temporary, expected: candidate) {
                writable = false; preserveExisting(temporary)
                throw ArchiveStoreError.rollbackIncomplete
            } else if candidate == nil, creationAttempted {
                // 无法获得候选inode证明时也不能无条件删除残留文件。
                writable = false; preserveExisting(temporary)
                throw ArchiveStoreError.rollbackIncomplete
            }
            if conflict || (error as? ArchiveStoreError) == .externalChange {
                writable = false; preserveExisting(fileName)
                throw ArchiveStoreError.externalChange
            }
            throw error
        }

        // 最终档案已经完成文件与目录fsync且读回一致；此后不再抛出“提交失败”。
        known = candidate; value = next
        // 已知旧版才允许清理。清理失败不反转已持久提交，只保留恢复文件并停止后续写入。
        if let previous, !removeKnown(temporary, expected: previous) {
            writable = false; preserveExisting(temporary)
        }
    }

    private func verifyCommitted(candidate: Snapshot?, previous: Snapshot?, temporary: String) throws {
        guard let candidate, try Self.read(directoryFD, name: fileName, maximumBytes: maximumBytes) == candidate else {
            throw ArchiveStoreError.externalChange
        }
        if let previous {
            guard try Self.read(directoryFD, name: temporary, maximumBytes: maximumBytes) == previous else {
                throw ArchiveStoreError.externalChange
            }
        }
    }

    /// 仅在final仍是本次完整候选时补偿。所有rename都保留未知内容，绝不无条件覆盖。
    private func compensate(candidate: Snapshot, previous: Snapshot?, temporary: String,
                            conflict: inout Bool) throws -> Bool {
        guard try Self.read(directoryFD, name: fileName, maximumBytes: maximumBytes) == candidate else {
            conflict = true; preserveExisting(temporary); preserveExisting(fileName); return false
        }
        if let previous {
            guard let displacedIdentity = try Self.identityAt(directoryFD, name: temporary) else { return false }
            do { if try Self.read(directoryFD, name: temporary, maximumBytes: maximumBytes) != previous { conflict = true } }
            catch { conflict = true }
            try faultHook(.beforeCompensation)
            guard renameatx_np(directoryFD, temporary, directoryFD, fileName, UInt32(RENAME_SWAP)) == 0 else {
                throw ArchiveStoreError.rollbackIncomplete
            }
            let movedIsOurs = (try? Self.read(directoryFD, name: temporary, maximumBytes: maximumBytes)) == candidate
            let restoredIdentity = try Self.identityAt(directoryFD, name: fileName)
            guard movedIsOurs, restoredIdentity == displacedIdentity else {
                // 检查与交换间有新编辑：只在final仍是刚放回的inode时交换回去，保留两份。
                conflict = true
                if restoredIdentity == displacedIdentity,
                   try Self.identityAt(directoryFD, name: temporary) != nil {
                    guard renameatx_np(directoryFD, temporary, directoryFD, fileName, UInt32(RENAME_SWAP)) == 0 else {
                        throw ArchiveStoreError.rollbackIncomplete
                    }
                    try syncDirectory()
                }
                preserveExisting(temporary); preserveExisting(fileName)
                return false
            }
            try faultHook(.afterCompensation)
            try faultHook(.beforeCompensationDirectorySync)
            try syncDirectory()
            guard try Self.identityAt(directoryFD, name: fileName) == displacedIdentity,
                  (try? Self.read(directoryFD, name: temporary, maximumBytes: maximumBytes)) == candidate else { return false }
            return removeKnown(temporary, expected: candidate)
        } else {
            // 初次创建的回退也先移动，不能在检查后直接unlink final。
            try faultHook(.beforeCompensation)
            guard renameatx_np(directoryFD, fileName, directoryFD, temporary, UInt32(RENAME_EXCL)) == 0 else {
                throw ArchiveStoreError.rollbackIncomplete
            }
            guard (try? Self.read(directoryFD, name: temporary, maximumBytes: maximumBytes)) == candidate else {
                conflict = true
                // 移出的是外部写者：只允许EXCL放回，不覆盖此刻可能出现的第三份内容。
                if try Self.identityAt(directoryFD, name: fileName) == nil {
                    guard renameatx_np(directoryFD, temporary, directoryFD, fileName, UInt32(RENAME_EXCL)) == 0 else {
                        throw ArchiveStoreError.rollbackIncomplete
                    }
                    try syncDirectory()
                }
                preserveExisting(temporary); preserveExisting(fileName)
                return false
            }
            try faultHook(.afterCompensation)
            try faultHook(.beforeCompensationDirectorySync)
            try syncDirectory()
            guard try Self.identityAt(directoryFD, name: fileName) == nil else {
                conflict = true; preserveExisting(temporary); preserveExisting(fileName); return false
            }
            return removeKnown(temporary, expected: candidate)
        }
    }

    private func validateDirectory() throws {
        try Self.requireDirectory(directory, identity: directoryIdentity)
    }
    private func directoryStillMatches() -> Bool { (try? validateDirectory()) != nil }
    private func syncDirectory() throws {
        guard fsync(directoryFD) == 0 else { throw ArchiveStoreError.unavailable }
    }
    private func preserveExisting(_ name: String) {
        if (try? Self.identityAt(directoryFD, name: name)) != nil, !preservedFiles.contains(name) {
            preservedFiles.append(name)
        }
    }
    /// 未知内容绝不删除；返回false使模块进入只读。清理目录项也要fsync。
    private func removeKnown(_ name: String, expected: Snapshot) -> Bool {
        do {
            guard let actual = try Self.read(directoryFD, name: name, maximumBytes: maximumBytes) else { return true }
            guard actual == expected, unlinkat(directoryFD, name, 0) == 0 else { return false }
            try syncDirectory(); return true
        } catch { return false }
    }

    private static func requireDirectory(_ location: URL, identity: Identity) throws {
        let fd = Darwin.open(location.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveStoreError.externalChange }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), Identity(info) == identity else {
            throw ArchiveStoreError.externalChange
        }
    }
    private static func identityAt(_ directory: Int32, name: String) throws -> Identity? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw ArchiveStoreError.unavailable
        }
        return Identity(info)
    }
    private static func recoveryNames(_ directory: Int32, transactionPrefix: String) throws -> (names: [String], mayBeTruncated: Bool) {
        let copy = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw ArchiveStoreError.unavailable }
        guard let entries = fdopendir(copy) else {
            Darwin.close(copy); throw ArchiveStoreError.unavailable
        }
        defer { closedir(entries) }
        var names: [String] = [], scanned = 0
        while true {
            errno = 0
            guard let entry = readdir(entries) else {
                guard errno == 0 else { throw ArchiveStoreError.unavailable }
                return (names.sorted(), false)
            }
            scanned += 1
            guard scanned <= 4_096 else { throw ArchiveStoreError.unavailable }
            let length = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length) { String(cString: $0) }
            }
            if name.hasPrefix(transactionPrefix) {
                names.append(name)
                if names.count == 32 { return (names.sorted(), true) }
            }
        }
    }
    private static func read(_ directory: Int32, name: String, maximumBytes: Int) throws -> Snapshot? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ArchiveStoreError.externalChange }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw ArchiveStoreError.externalChange
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let maximum = min(buffer.count, maximumBytes + 1 - bytes.count)
            let count = Darwin.read(fd, &buffer, maximum)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ArchiveStoreError.unavailable }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= maximumBytes else { throw ArchiveStoreError.externalChange }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Identity(before) == Identity(after), before.st_size == after.st_size,
              before.st_size == bytes.count, before.st_uid == after.st_uid, before.st_nlink == after.st_nlink,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ArchiveStoreError.externalChange
        }
        return Snapshot(identity: Identity(after), bytes: bytes)
    }
    private static func writeCandidate(_ directory: Int32, name: String, bytes: Data, proof: inout Snapshot?, maximumBytes: Int) throws {
        guard bytes.count <= maximumBytes else { throw ArchiveStoreError.unavailable }
        let fd = openat(directory, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ArchiveStoreError.unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ArchiveStoreError.unavailable }
        let identity = Identity(info)
        proof = Snapshot(identity: identity, bytes: Data())
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ArchiveStoreError.unavailable }
                offset += count
                proof = Snapshot(identity: identity, bytes: Data(bytes.prefix(offset)))
            }
        }
        guard fsync(fd) == 0 else { throw ArchiveStoreError.unavailable }
        guard try read(directory, name: name, maximumBytes: maximumBytes) == proof else { throw ArchiveStoreError.externalChange }
    }
}
