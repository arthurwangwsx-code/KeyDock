import Darwin
import Foundation

/// 只读持有已存在的private目录出生身份；路径重绑定后永久拒绝，不创建或改权限。
@MainActor public final class PrivateDirectoryIdentity {
    private let descriptor: Int32
    private let directory: URL
    private let device: dev_t, inode: ino_t, owner: uid_t, mode: mode_t
    private var invalidated = false
    public init(directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveStoreError.unavailable }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else {
            Darwin.close(fd); throw ArchiveStoreError.unavailable
        }
        var entry = stat()
        guard lstat(directory.path, &entry) == 0, entry.st_dev == s.st_dev, entry.st_ino == s.st_ino,
              entry.st_uid == s.st_uid, entry.st_mode == s.st_mode else {
            Darwin.close(fd); throw ArchiveStoreError.externalChange
        }
        descriptor = fd; self.directory = directory
        device = s.st_dev; inode = s.st_ino; owner = s.st_uid; mode = s.st_mode
    }
    deinit { Darwin.close(descriptor) }
    public func validateCurrent() throws {
        guard !invalidated else { throw ArchiveStoreError.externalChange }
        var s = stat(), held = stat()
        guard lstat(directory.path, &s) == 0, fstat(descriptor, &held) == 0,
              s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), s.st_dev == device, s.st_ino == inode,
              s.st_uid == owner, s.st_mode == mode, held.st_dev == device, held.st_ino == inode,
              held.st_uid == owner, held.st_mode == mode else { invalidated = true; throw ArchiveStoreError.externalChange }
    }
}
