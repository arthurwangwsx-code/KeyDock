import CommandCore
import Darwin
import Foundation

/// 只读旧源证明。未确认与已确认空数组严格分开；不创建、改权限或清理任何文件。
@MainActor public final class LegacyApplicationActionSnapshot {
    public private(set) var actions: [SavedApplicationAction]?
    private let directory: URL
    private let directoryFD: Int32
    private let directoryIdentity: Identity
    private let original: FileSnapshot?
    private var invalidated = false
    private static let fileName = "application-actions.json"
    private static let recoveryPrefix = ".application-actions-transaction-"
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t, owner: uid_t, mode: mode_t
        init(_ s: stat) { device = s.st_dev; inode = s.st_ino; owner = s.st_uid; mode = s.st_mode }
    }
    private struct FileSnapshot: Equatable {
        let identity: Identity
        let bytes: Data
        let changedSeconds: Int, changedNanoseconds: Int
        let modifiedSeconds: Int, modifiedNanoseconds: Int
        init(_ s: stat, bytes: Data) {
            identity = .init(s); self.bytes = bytes
            changedSeconds = s.st_ctimespec.tv_sec; changedNanoseconds = s.st_ctimespec.tv_nsec
            modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanoseconds = s.st_mtimespec.tv_nsec
        }
    }
    public init(directory: URL) throws {
        let path = directory.standardizedFileURL
        let fd = Darwin.open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveStoreError.unavailable }
        var owned = false; defer { if !owned { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw ArchiveStoreError.unavailable }
        let identity = Identity(info)
        try Self.requireDirectory(path, identity: identity)
        try Self.requireNoRecovery(fd)
        let snapshot = try Self.read(fd)
        let decoded = try snapshot.map { try ApplicationActionArchive.decode($0.bytes).actions } ?? []
        try Self.requireNoRecovery(fd); try Self.requireDirectory(path, identity: identity)
        guard try Self.read(fd) == snapshot else { throw ArchiveStoreError.externalChange }
        self.directory = path; directoryFD = fd; directoryIdentity = identity; original = snapshot; actions = decoded
        owned = true
    }
    deinit { Darwin.close(directoryFD) }
    public func validateCurrent() throws {
        guard !invalidated else { throw ArchiveStoreError.externalChange }
        do {
            try Self.requireDirectory(directory, identity: directoryIdentity)
            try Self.requireNoRecovery(directoryFD)
            guard try Self.read(directoryFD) == original else { throw ArchiveStoreError.externalChange }
            try Self.requireNoRecovery(directoryFD); try Self.requireDirectory(directory, identity: directoryIdentity)
        } catch { invalidated = true; actions = nil; throw error }
    }
    private static func requireDirectory(_ url: URL, identity: Identity) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, Identity(info) == identity else { throw ArchiveStoreError.externalChange }
    }
    private static func requireNoRecovery(_ fd: Int32) throws {
        let copy = dup(fd); guard copy >= 0 else { throw ArchiveStoreError.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw ArchiveStoreError.unavailable }
        defer { closedir(stream) }; rewinddir(stream)
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ArchiveStoreError.unavailable }; return
            }
            count += 1; guard count <= 8192 else { throw ArchiveStoreError.unavailable }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name.hasPrefix(recoveryPrefix) { throw ArchiveStoreError.unavailable }
        }
    }
    private static func read(_ directory: Int32) throws -> FileSnapshot? {
        let fd = openat(directory, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ArchiveStoreError.unavailable }; defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == geteuid(),
              before.st_nlink == 1, before.st_mode & 0o022 == 0, before.st_size >= 0, before.st_size <= ApplicationActionArchive.maximumBytes else { throw ArchiveStoreError.unavailable }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let size = min(buffer.count, ApplicationActionArchive.maximumBytes + 1 - bytes.count)
            let count = Darwin.read(fd, &buffer, size)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ArchiveStoreError.unavailable }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count)); guard bytes.count <= ApplicationActionArchive.maximumBytes else { throw ArchiveStoreError.unavailable }
        }
        var after = stat(), entry = stat()
        guard fstat(fd, &after) == 0, fstatat(directory, fileName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_nlink == 1, before.st_size == bytes.count, after.st_size == bytes.count, entry.st_size == bytes.count,
              FileSnapshot(before, bytes: bytes) == FileSnapshot(after, bytes: bytes),
              FileSnapshot(after, bytes: bytes) == FileSnapshot(entry, bytes: bytes) else { throw ArchiveStoreError.externalChange }
        return .init(after, bytes: bytes)
    }
}
