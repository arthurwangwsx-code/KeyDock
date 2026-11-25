import Foundation
import Darwin

enum TaskMaterialReadKind: Hashable, Sendable { case header, payload, control }

/// 只由一个actor持有；固定目录FD和生命周期flock，deinit释放OS资源。
final class TaskMaterialFiles: @unchecked Sendable {
    typealias Fault = @Sendable (TaskMaterialWriteRole, TaskMaterialPersistencePoint, String) -> Int32?
    typealias ReadObserver = @Sendable (TaskMaterialReadKind, Int) -> Void
    static let controlName = "control.json"
    static let lockName = ".owner.lock"
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private let location: URL
    private let directoryFD: Int32
    private let lockFD: Int32
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let fault: Fault
    private let observeRead: ReadObserver

    init(directory: URL, create: Bool, fault: @escaping Fault = { _, _, _ in nil },
         observeRead: @escaping ReadObserver = { _, _ in }) throws {
        let descriptor = try Self.openDirectory(directory, create: create)
        var adopted = false, owner: Int32 = -1
        defer { if !adopted { if owner >= 0 { close(owner) }; close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw TaskMaterialError.unsafeEntry }
        owner = openat(descriptor, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard owner >= 0 else { throw TaskMaterialError.io(errno) }
        let lockInfo = try Self.fileInfo(owner)
        guard lockInfo.st_size == 0 else { throw TaskMaterialError.unsafeEntry }
        guard flock(owner, LOCK_EX | LOCK_NB) == 0 else { throw TaskMaterialError.busy }
        self.location = directory; directoryFD = descriptor; lockFD = owner
        directoryDevice = info.st_dev; directoryInode = info.st_ino
        self.fault = fault; self.observeRead = observeRead; adopted = true
    }

    deinit { close(lockFD); close(directoryFD) }

    func requireBoundDirectory() throws {
        let current = try Self.openDirectory(location, create: false)
        defer { close(current) }
        var actual = stat(), pinned = stat()
        guard fstat(current, &actual) == 0, fstat(directoryFD, &pinned) == 0,
              actual.st_uid == geteuid(), actual.st_mode & 0o077 == 0,
              actual.st_dev == directoryDevice, actual.st_ino == directoryInode,
              pinned.st_dev == directoryDevice, pinned.st_ino == directoryInode else { throw TaskMaterialError.changed }
        let owner = try Self.fileInfo(lockFD)
        guard owner.st_size == 0, try identity(Self.lockName) == Self.identity(owner) else { throw TaskMaterialError.changed }
    }

    func names() throws -> [String] {
        try requireBoundDirectory()
        let cursor = openat(directoryFD, ".", Self.directoryFlags)
        guard cursor >= 0 else { throw TaskMaterialError.io(errno) }
        guard let stream = fdopendir(cursor) else { close(cursor); throw TaskMaterialError.io(errno) }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw TaskMaterialError.io(errno) }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw TaskMaterialError.unsafeEntry }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= TaskMaterialLimits.enumerationCount else { throw TaskMaterialError.capacity }
        }
        try requireBoundDirectory()
        return result.sorted()
    }

    func identity(_ name: String) throws -> TaskMaterialFileIdentity? {
        try Self.validName(name)
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw TaskMaterialError.io(errno)
        }
        try Self.requireRegular(info)
        return Self.identity(info)
    }

    func readHeader(_ key: TaskMaterialKey) throws -> TaskMaterialHandle? {
        try requireBoundDirectory()
        guard let expected = try identity(key.fileName) else { return nil }
        let descriptor = try openRead(key.fileName, expected: expected, maximum: TaskMaterialLimits.recordBytes)
        defer { close(descriptor) }
        let (header, hash) = try header(descriptor, expected: expected)
        guard header.key == key else { throw TaskMaterialError.invalidHeader }
        try requireUnchanged(descriptor, name: key.fileName, expected: expected)
        return .init(header: header, fileIdentity: expected, headerSHA256: hash)
    }

    func readBody(_ handle: TaskMaterialHandle) throws -> SelectedTaskMaterial {
        try requireBoundDirectory()
        let name = handle.key.fileName, expected = handle.fileIdentity
        let descriptor = try openRead(name, expected: expected, maximum: TaskMaterialLimits.recordBytes)
        defer { close(descriptor) }
        let (header, hash) = try header(descriptor, expected: expected)
        guard hash == handle.headerSHA256, header.key == handle.key, header.version == handle.version else { throw TaskMaterialError.changed }
        let bytes = try readExactly(descriptor, count: header.payloadBytes, kind: .payload)
        try requireUnchanged(descriptor, name: name, expected: expected)
        do { return try TaskMaterialFormat.decodePayload(bytes, header: header) }
        catch let error as TaskMaterialError { throw error }
        catch { throw TaskMaterialError.invalidContent }
    }

    func readControl() throws -> (Data, TaskMaterialFileIdentity)? {
        try requireBoundDirectory()
        guard let expected = try identity(Self.controlName) else { return nil }
        let descriptor = try openRead(Self.controlName, expected: expected, maximum: TaskMaterialLimits.controlBytes)
        defer { close(descriptor) }
        let bytes = try readExactly(descriptor, count: expected.size, kind: .control)
        try requireUnchanged(descriptor, name: Self.controlName, expected: expected)
        return (bytes, expected)
    }

    func writeBody(_ bytes: Data, key: TaskMaterialKey, expected: TaskMaterialFileIdentity?, validate: () throws -> Void,
                   commit: (() throws -> Void) throws -> Void) throws {
        guard bytes.count <= TaskMaterialLimits.recordBytes else { throw TaskMaterialError.capacity }
        let temporary = ".material-v1-" + String(key.fileName.dropLast(".kdmaterial".count)) + "-" + UUID().uuidString.lowercased() + ".tmp"
        try write(bytes, name: key.fileName, temporary: temporary, expected: expected, role: .body, validate: validate, commit: commit)
    }

    func writeControl(_ bytes: Data, expected: TaskMaterialFileIdentity?) throws {
        guard bytes.count <= TaskMaterialLimits.controlBytes else { throw TaskMaterialError.capacity }
        try write(bytes, name: Self.controlName, temporary: ".control-v1-" + UUID().uuidString.lowercased() + ".tmp",
            expected: expected, role: .control, validate: {}, commit: { try $0() })
    }

    func remove(_ name: String, expected: TaskMaterialFileIdentity) throws {
        guard name != Self.lockName, name != Self.controlName else { throw TaskMaterialError.unsafeEntry }
        try requireBoundDirectory()
        guard try identity(name) == expected else { throw TaskMaterialError.changed }
        try injected(.body, .beforeDelete, name)
        try requireBoundDirectory()
        guard try identity(name) == expected else { throw TaskMaterialError.changed }
        guard unlinkat(directoryFD, name, 0) == 0 else { throw TaskMaterialError.io(errno) }
        guard fsync(directoryFD) == 0 else { throw TaskMaterialError.durabilityUncertain(errno) }
        try requireBoundDirectory()
    }

    func synchronizeDirectory() throws {
        try requireBoundDirectory()
        guard fsync(directoryFD) == 0 else { throw TaskMaterialError.durabilityUncertain(errno) }
        try requireBoundDirectory()
    }

    private func header(_ descriptor: Int32, expected: TaskMaterialFileIdentity) throws -> (TaskMaterialHeader, String) {
        let prefix = try readExactly(descriptor, count: TaskMaterialFormat.prefixBytes, kind: .header)
        let count = try TaskMaterialFormat.headerLength(prefix)
        guard expected.size >= TaskMaterialFormat.prefixBytes + count else { throw TaskMaterialError.invalidHeader }
        let bytes = try readExactly(descriptor, count: count, kind: .header)
        do {
            return (try TaskMaterialFormat.decodeHeader(bytes, fileBytes: expected.size, headerBytes: count), TaskMaterialFormat.digest(bytes))
        } catch let error as TaskMaterialError { throw error }
        catch { throw TaskMaterialError.invalidHeader }
    }

    private func openRead(_ name: String, expected: TaskMaterialFileIdentity, maximum: Int) throws -> Int32 {
        guard expected.size >= 0, expected.size <= maximum else { throw TaskMaterialError.capacity }
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw TaskMaterialError.io(errno) }
        do {
            guard Self.identity(try Self.fileInfo(descriptor)) == expected else { throw TaskMaterialError.changed }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func readExactly(_ descriptor: Int32, count: Int, kind: TaskMaterialReadKind) throws -> Data {
        guard count >= 0, count <= TaskMaterialLimits.recordBytes else { throw TaskMaterialError.capacity }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: min(16_384, max(1, count)))
        while bytes.count < count {
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, min($0.count, count - bytes.count)) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw amount == 0 ? TaskMaterialError.changed : .io(errno) }
            bytes.append(contentsOf: buffer.prefix(amount)); observeRead(kind, amount)
        }
        return bytes
    }

    private func requireUnchanged(_ descriptor: Int32, name: String, expected: TaskMaterialFileIdentity) throws {
        guard Self.identity(try Self.fileInfo(descriptor)) == expected, try identity(name) == expected else { throw TaskMaterialError.changed }
        try requireBoundDirectory()
    }

    private func write(_ bytes: Data, name: String, temporary: String, expected: TaskMaterialFileIdentity?, role: TaskMaterialWriteRole,
                       validate: () throws -> Void, commit: (() throws -> Void) throws -> Void) throws {
        try requireBoundDirectory(); try validate()
        guard try identity(name) == expected else { throw TaskMaterialError.changed }
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw TaskMaterialError.io(errno) }
        let initial: stat
        do { initial = try Self.fileInfo(descriptor) }
        catch { close(descriptor); throw error }
        var renamed = false
        defer {
            var current = stat()
            if fstatat(directoryFD, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == initial.st_dev, current.st_ino == initial.st_ino {
                _ = unlinkat(directoryFD, temporary, 0)
            }
            close(descriptor)
        }
        do {
            try bytes.withUnsafeBytes { buffer in
                guard let start = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let amount = Darwin.write(descriptor, start.advanced(by: offset), buffer.count - offset)
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw TaskMaterialError.io(errno) }; offset += amount
                }
            }
            try injected(role, .beforeFileSync, name)
            guard fsync(descriptor) == 0 else { throw TaskMaterialError.io(errno) }
            let synchronized = Self.identity(try Self.fileInfo(descriptor))
            try validate(); try requireBoundDirectory()
            guard try identity(name) == expected else { throw TaskMaterialError.changed }
            try injected(role, .beforeRename, name)
            try commit {
                try requireBoundDirectory()
                guard Self.identity(try Self.fileInfo(descriptor)) == synchronized,
                      try identity(temporary) == synchronized else { throw TaskMaterialError.changed }
                guard try identity(name) == expected else { throw TaskMaterialError.changed }
                guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw TaskMaterialError.io(errno) }
                renamed = true
            }
            guard renamed else { throw TaskMaterialError.io(EIO) }
            try injected(role, .afterRename, name)
            try injected(role, .beforeDirectorySync, name)
            guard fsync(directoryFD) == 0 else { throw TaskMaterialError.io(errno) }
            try requireBoundDirectory()
        } catch {
            if renamed {
                if case TaskMaterialError.io(let code) = error { throw TaskMaterialError.durabilityUncertain(code) }
                throw TaskMaterialError.durabilityUncertain(EIO)
            }
            throw error
        }
    }

    private func injected(_ role: TaskMaterialWriteRole, _ point: TaskMaterialPersistencePoint, _ name: String) throws {
        if let code = fault(role, point, name) { throw TaskMaterialError.io(code > 0 ? code : EIO) }
    }
    private static func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= Int(NAME_MAX), !name.contains("/"), !name.contains("\0") else { throw TaskMaterialError.unsafeEntry }
    }
    private static func requireRegular(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size >= 0 else { throw TaskMaterialError.unsafeEntry }
    }
    private static func fileInfo(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw TaskMaterialError.io(errno) }
        try requireRegular(info); return info
    }
    private static func identity(_ info: stat) -> TaskMaterialFileIdentity {
        .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), size: Int(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec), mode: UInt16(info.st_mode))
    }
    private static func openDirectory(_ location: URL, create: Bool) throws -> Int32 {
        guard location.isFileURL, location.path.hasPrefix("/"), !location.pathComponents.contains("..") else { throw TaskMaterialError.unavailable }
        var descriptor = Darwin.open("/", directoryFlags)
        guard descriptor >= 0 else { throw TaskMaterialError.io(errno) }
        do {
            for component in location.pathComponents.dropFirst() {
                var child = openat(descriptor, component, directoryFlags)
                if child < 0, errno == ENOENT, create {
                    var parent = stat()
                    guard fstat(descriptor, &parent) == 0, parent.st_uid == geteuid() else { throw TaskMaterialError.unsafeEntry }
                    guard mkdirat(descriptor, component, mode_t(0o700)) == 0, fsync(descriptor) == 0 else { throw TaskMaterialError.io(errno) }
                    child = openat(descriptor, component, directoryFlags)
                    if child >= 0, fsync(child) != 0 { let code = errno; close(child); throw TaskMaterialError.io(code) }
                }
                guard child >= 0 else { throw errno == ENOENT ? TaskMaterialError.missing : .io(errno) }
                close(descriptor); descriptor = child
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw TaskMaterialError.unsafeEntry }
            return descriptor
        } catch { close(descriptor); throw error }
    }
}
