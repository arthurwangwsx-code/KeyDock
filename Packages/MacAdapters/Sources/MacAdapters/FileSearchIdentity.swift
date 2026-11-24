import Foundation
import Darwin
import CryptoKit

struct FileSearchDirectoryIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ value: stat) {
        device = UInt64(truncatingIfNeeded: value.st_dev)
        inode = UInt64(truncatingIfNeeded: value.st_ino)
    }
    var revision: String { String(device) + ":" + String(inode) }
}
struct FileSearchObjectIdentity: Sendable, Equatable {
    let directory: FileSearchDirectoryIdentity
    let size: Int64
    let mode: UInt16
    let links: UInt64
    let flags: UInt32
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    init(_ value: stat) {
        directory = .init(value); size = Int64(value.st_size); mode = UInt16(truncatingIfNeeded: value.st_mode)
        links = UInt64(truncatingIfNeeded: value.st_nlink); flags = value.st_flags
        modificationSeconds = Int64(value.st_mtimespec.tv_sec); modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec); changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    var revision: String {
        [directory.revision, String(size), String(mode), String(links), String(flags), String(modificationSeconds),
         String(modificationNanoseconds), String(changeSeconds), String(changeNanoseconds)].joined(separator: ":")
    }
}
struct FileSearchRootIdentity: Sendable, Equatable {
    let requestedURL: URL
    let canonicalURL: URL
    let identity: FileSearchDirectoryIdentity
}
enum FileSearchPOSIX {
    struct RootFailure: Error { let status: FileSearchScopeStatus }
    static func prepare(_ original: URL) throws -> (FileSearchRootIdentity, Int32) {
        let requested = original.standardizedFileURL
        var value = stat()
        guard Darwin.lstat(requested.path, &value) == 0 else { throw RootFailure(status: .unavailable) }
        if isSymbolicLink(value) { throw RootFailure(status: .symbolicLinkExcluded) }
        guard isDirectory(value) else { throw RootFailure(status: .notDirectory) }
        if package(requested) { throw RootFailure(status: .packageExcluded) }
        let canonical = try canonicalURL(requested)
        let fd: Int32
        do { fd = try openDirectoryPath(canonical.path) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RootFailure(status: .changed) }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0, isDirectory(opened),
              FileSearchDirectoryIdentity(opened) == FileSearchDirectoryIdentity(value) else {
            Darwin.close(fd); throw RootFailure(status: .changed)
        }
        return (.init(requestedURL: requested, canonicalURL: canonical, identity: .init(opened)), fd)
    }
    /// 保留真实目录对象身份，同时复核原用户路径没有被换成另一目标。
    static func verifiedRoot(_ root: FileSearchRootIdentity) throws -> Int32 {
        try Task.checkCancellation()
        var requested = stat()
        guard Darwin.lstat(root.requestedURL.path, &requested) == 0, isDirectory(requested),
              !isSymbolicLink(requested), FileSearchDirectoryIdentity(requested) == root.identity,
              (try? canonicalURL(root.requestedURL).path) == root.canonicalURL.path else { throw FileSearchError.scopeChanged }
        let fd: Int32
        do { fd = try openDirectoryPath(root.canonicalURL.path) }
        catch is CancellationError { throw CancellationError() }
        catch { throw FileSearchError.scopeChanged }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0, FileSearchDirectoryIdentity(opened) == root.identity else {
            Darwin.close(fd); throw FileSearchError.scopeChanged
        }
        return fd
    }
    /// 不打开文件正文；只以fstatat(AT_SYMLINK_NOFOLLOW)核对条目与修订。
    static func validate(_ result: FileSearchResult) throws -> URL {
        let root = try verifiedRoot(result.scope)
        defer { Darwin.close(root) }
        let parents = Array(result.relativeComponents.dropLast())
        guard parents.count == result.directoryChain.count,
              let filename = result.relativeComponents.last, validComponent(filename) else { throw FileSearchError.pathChanged }
        var directory = Darwin.fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else { throw FileSearchError.pathChanged }
        defer { Darwin.close(directory) }
        for (index, component) in parents.enumerated() {
            try Task.checkCancellation()
            guard validComponent(component) else { throw FileSearchError.pathChanged }
            let next = Darwin.openat(directory, component, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw FileSearchError.pathChanged }
            var value = stat()
            guard Darwin.fstat(next, &value) == 0, isDirectory(value), !hidden(component, value),
                  FileSearchDirectoryIdentity(value) == result.directoryChain[index] else {
                Darwin.close(next); throw FileSearchError.pathChanged
            }
            Darwin.close(directory); directory = next
        }
        try Task.checkCancellation()
        var value = stat()
        guard Darwin.fstatat(directory, filename, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw FileSearchError.targetChanged }
        guard isRegularFile(value), !isSymbolicLink(value) else { throw FileSearchError.notRegularFile }
        guard FileSearchObjectIdentity(value) == result.identity else { throw FileSearchError.targetChanged }
        return result.url
    }
    /// Foundation标准化会将/private/var折回/var别名，不能再用于O_NOFOLLOW逐级遍历。
    private static func canonicalURL(_ url:URL) throws -> URL {
        guard let path = Darwin.realpath(url.path,nil) else { throw FileSearchError.scopeChanged }
        defer { free(path) }
        return URL(fileURLWithPath:String(cString:path),isDirectory:true)
    }
    private static func openDirectoryPath(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw FileSearchError.pathChanged }
        var current = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw FileSearchError.pathChanged }
        var transferred = false
        defer { if !transferred { Darwin.close(current) } }
        for component in path.split(separator: "/").map(String.init) {
            try Task.checkCancellation()
            guard validComponent(component) else { throw FileSearchError.pathChanged }
            let next = Darwin.openat(current, component, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw FileSearchError.pathChanged }
            Darwin.close(current); current = next
        }
        transferred = true; return current
    }
    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }
    static func isDirectory(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFDIR }
    static func isRegularFile(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFREG }
    static func isSymbolicLink(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFLNK }
    static func hidden(_ name: String, _ value: stat) -> Bool {
        name.hasPrefix(".") || (value.st_flags & UInt32(UF_HIDDEN)) != 0
    }
    static func package(_ url: URL) -> Bool {
        let conventional: Set<String> = ["app", "bundle", "framework", "pkg", "plugin", "appex", "xcodeproj", "xcworkspace", "playground", "photoslibrary", "photolibrary", "rtfd", "pages", "numbers", "key", "band", "logicx", "fcpbundle", "sparsebundle", "scptd", "mdimporter", "prefpane", "qlgenerator", "saver"]
        return conventional.contains(url.pathExtension.lowercased()) || (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
