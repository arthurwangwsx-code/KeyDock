import Foundation
import Darwin

public enum RuntimeDirectoryLeaseError: Error, Equatable { case alreadyOwned, invalidDirectory, io(Int32) }

/// GUI进程持有的数据目录排他owner；避免两份App同时调度、保存配置。不是系统权限沙箱。
public final class RuntimeDirectoryLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw RuntimeDirectoryLeaseError.invalidDirectory }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let parent = Darwin.open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parent >= 0 else { throw RuntimeDirectoryLeaseError.invalidDirectory }; defer { Darwin.close(parent) }
        let fd = openat(parent,"runtime-owner.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,mode_t(0o600))
        guard fd >= 0 else { throw RuntimeDirectoryLeaseError.io(errno) }
        var transferred = false; defer { if !transferred { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), fchmod(fd,mode_t(0o600)) == 0 else { throw RuntimeDirectoryLeaseError.invalidDirectory }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw RuntimeDirectoryLeaseError.alreadyOwned }
            throw RuntimeDirectoryLeaseError.io(errno)
        }
        descriptor = fd; transferred = true
    }
    deinit { _ = flock(descriptor,LOCK_UN); Darwin.close(descriptor) }
}
