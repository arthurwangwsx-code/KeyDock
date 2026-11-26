import AppKit
import CryptoKit
import Darwin
import Foundation

/// 宿主提供的窄能力；模型不能从字符串参数创建此对象。
@MainActor public protocol DesktopReviewRuntimeScope: AnyObject {
    var dataDirectory: URL { get }
    var sessionDirectory: URL { get }
    var initialConfigurationData: Data? { get }
    var isCurrent: Bool { get }
    var targetIdentity: TargetIdentity { get }
    var diagnostic: DesktopReviewInvalidation? { get }
    var targetDiagnostic: DesktopReviewTargetDiagnostic? { get }
    func permits(_ target: TargetIdentity) -> Bool
    func revoke()
    func prepareClipboardStorage() throws -> any ClipboardStorageLifetime
    func writeConfiguration(_ data: Data, to url: URL) throws
}

/// 只报告固定类别；不记录正文、路径、凭据或原应用内容。
public enum DesktopReviewInvalidation: String, Sendable {
    case explicitlyRevoked, directoryIdentityChanged, markerMetadataChanged, ownerLockMetadataChanged
    case boundAppMetadataChanged, configurationIdentityChanged, clipboardStorageChanged, targetIdentityChanged
}
extension DesktopReviewRuntimeScope {
    public var diagnostic: DesktopReviewInvalidation? { nil }
    public var targetDiagnostic: DesktopReviewTargetDiagnostic? { nil }
}

public struct DesktopReviewBuildBinding: Codable, Sendable {
    public let rootParent: String
    public let reviewBundleIdentifier: String
    public let fixtureBundleIdentifier: String
    public let fixtureAppPath: String
    public let fixtureBinarySHA256: String
    public let fixtureInfoSHA256: String
    public init(rootParent: String, reviewBundleIdentifier: String, fixtureBundleIdentifier: String,
                fixtureAppPath: String, fixtureBinarySHA256: String, fixtureInfoSHA256: String) {
        self.rootParent = rootParent; self.reviewBundleIdentifier = reviewBundleIdentifier
        self.fixtureBundleIdentifier = fixtureBundleIdentifier; self.fixtureAppPath = fixtureAppPath
        self.fixtureBinarySHA256 = fixtureBinarySHA256; self.fixtureInfoSHA256 = fixtureInfoSHA256
    }
}

public enum DesktopReviewError: Error, Equatable { case invalidScope, alreadyOwned, unavailable, io(Int32) }

struct DesktopReviewMarker: Codable, Sendable {
    let schemaVersion: Int
    let rootID: UUID
    let reviewBundleIdentifier: String
    let fixturePID: Int32
    let fixtureLaunchTime: Double
}

struct DesktopReviewProcessIdentity: Sendable {
    let pid: Int32
    let launchTime: Double
    let bundleIdentifier: String
    let appPath: String
    let executablePath: String
}

/// 只针对受控合成宿主的合作式身份围栏，不是同UID恶意进程沙箱。
@MainActor public final class DesktopReviewScope: DesktopReviewRuntimeScope {
    public nonisolated static let bundleIdentifier = "com.arthurwangwsx.KeyDock.desktopreview"
    public nonisolated static let fixtureBundleIdentifier = "com.arthurwangwsx.KeyDock.desktopreview.fixture"
    public nonisolated static let fixtureExecutableName = "KeyDockDesktopReviewFixture"
    private let resources: DesktopReviewResources
    private let probe: @MainActor (Int32) -> DesktopReviewProcessSnapshot?
    private var revoked = false
    public private(set) var targetDiagnostic: DesktopReviewTargetDiagnostic?
    public var dataDirectory: URL { resources.dataDirectory }
    public var sessionDirectory: URL { resources.sessionDirectory }
    public var initialConfigurationData: Data? { resources.configuration }
    public var targetIdentity: TargetIdentity {
        .init(pid: resources.marker.fixturePID, launchDate: Date(timeIntervalSince1970: resources.marker.fixtureLaunchTime), name: "KeyDock Desktop Review Fixture")
    }
    public var isCurrent: Bool {
        guard !revoked else { return false }
        guard resources.isCurrent() else { revoke(); return false }
        let expected = DesktopReviewProcessIdentity(pid: resources.marker.fixturePID, launchTime: resources.marker.fixtureLaunchTime,
            bundleIdentifier: Self.fixtureBundleIdentifier, appPath: resources.binding.fixtureAppPath, executablePath: resources.executablePath)
        if let failure = DesktopReviewTargetIdentityCheck.failure(expected: expected, actual: probe(resources.marker.fixturePID)) {
            targetDiagnostic = failure; resources.invalidate(reason: .targetIdentityChanged); revoke(); return false
        }
        return true
    }
    public var diagnostic: DesktopReviewInvalidation? { resources.diagnostic }
    public func permits(_ target: TargetIdentity) -> Bool {
        isCurrent && target.pid == resources.marker.fixturePID && target.launchDate?.timeIntervalSince1970 == resources.marker.fixtureLaunchTime
    }
    public func revoke() { revoked = true; resources.invalidate() }
    public func prepareClipboardStorage() throws -> any ClipboardStorageLifetime {
        guard isCurrent else { throw DesktopReviewError.unavailable }
        try resources.prepareClipboardStorage()
        guard isCurrent else { throw DesktopReviewError.unavailable }
        return resources
    }
    public func activateTarget() -> Bool {
        guard isCurrent else { return false }
        guard let app = NSRunningApplication(processIdentifier: resources.marker.fixturePID),
              app.launchDate?.timeIntervalSince1970 == resources.marker.fixtureLaunchTime else { return false }
        return app.activate()
    }
    public func writeConfiguration(_ data: Data, to url: URL) throws {
        guard isCurrent, url == dataDirectory.appendingPathComponent("configuration.json"), data.count <= 65_536 else { throw DesktopReviewError.invalidScope }
        try resources.writeConfiguration(data)
        guard isCurrent else { throw DesktopReviewError.invalidScope }
    }
    public static func prepare(binding: DesktopReviewBuildBinding, root: URL) async throws -> DesktopReviewScope {
        try await prepare(binding: binding, root: root, probe: nativeProbe)
    }
    static func prepare(binding: DesktopReviewBuildBinding, root: URL,
                        probe: @escaping @MainActor (Int32) -> DesktopReviewProcessSnapshot?,
                        beforeHash: @escaping @Sendable () -> Void = {}) async throws -> DesktopReviewScope {
        let worker = Task.detached(priority: .userInitiated) { try DesktopReviewResources.prepare(binding: binding, root: root, beforeHash: beforeHash) }
        let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        let scope = DesktopReviewScope(resources: prepared, probe: probe)
        guard scope.isCurrent else { throw DesktopReviewError.unavailable }
        return scope
    }
    private init(resources: DesktopReviewResources, probe: @escaping @MainActor (Int32) -> DesktopReviewProcessSnapshot?) {
        self.resources = resources; self.probe = probe
    }
    private static func nativeProbe(_ pid: Int32) -> DesktopReviewProcessSnapshot? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return .init(pid: app.processIdentifier, isTerminated: app.isTerminated, launchTime: app.launchDate?.timeIntervalSince1970,
            bundleIdentifier: app.bundleIdentifier, appPath: app.bundleURL?.path, executablePath: app.executableURL?.path)
    }
}

private struct ReviewFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t
    let birthSeconds: Int
    let birthNanoseconds: Int
    let size: off_t
    let links: nlink_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; owner = s.st_uid; mode = s.st_mode
        birthSeconds = s.st_birthtimespec.tv_sec; birthNanoseconds = s.st_birthtimespec.tv_nsec
        size = s.st_size; links = s.st_nlink
        modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanoseconds = s.st_mtimespec.tv_nsec
        changedSeconds = s.st_ctimespec.tv_sec; changedNanoseconds = s.st_ctimespec.tv_nsec
    }
    func matches(_ other: Self, directory: Bool) -> Bool {
        if !directory { return self == other }
        // 合法新建子目录会改变目录时间、size和nlink，不能据此撤销owner。
        return device == other.device && inode == other.inode && owner == other.owner && mode == other.mode &&
            birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
    }
}

private final class DesktopReviewResources: @unchecked Sendable, ClipboardStorageLifetime {
    struct Node {
        let descriptor: Int32
        let parent: Int32
        let name: String
        let directory: Bool
        let identity: ReviewFileIdentity
    }
    let binding: DesktopReviewBuildBinding
    let root: URL
    var nodes: [Node] = []
    var directories: [String: Int32] = [:]
    var lock: Int32 = -1
    var dataFD: Int32 = -1
    var clipboardFD: Int32 = -1
    var clipboardIdentity: ReviewFileIdentity?
    private let validityLock = NSLock()
    private var invalidated = false
    private var firstFailure: DesktopReviewInvalidation?
    var diagnostic: DesktopReviewInvalidation? { validityLock.lock(); defer { validityLock.unlock() }; return firstFailure }
    func invalidate(reason: DesktopReviewInvalidation = .explicitlyRevoked) {
        validityLock.lock(); invalidated = true; if firstFailure == nil { firstFailure = reason }; validityLock.unlock()
    }
    private func failed(_ reason: DesktopReviewInvalidation) -> Bool {
        if firstFailure == nil { firstFailure = reason }; return false
    }
    var databaseURL: URL { dataDirectory.appendingPathComponent("clipboard.sqlite") }
    func validate() throws {
        guard clipboardFD >= 0, isCurrent() else { throw DesktopReviewError.unavailable }
    }
    var marker: DesktopReviewMarker!
    var configuration: Data?
    private var expectedConfigurationIdentity: ReviewFileIdentity?
    var dataDirectory: URL { root.appendingPathComponent("Data", isDirectory: true) }
    var sessionDirectory: URL!
    var executablePath: String { binding.fixtureAppPath + "/Contents/MacOS/" + DesktopReviewScope.fixtureExecutableName }
    init(binding: DesktopReviewBuildBinding, root: URL) { self.binding = binding; self.root = root }
    deinit { close() }
    func close() {
        if clipboardFD >= 0 { Darwin.close(clipboardFD); clipboardFD = -1 }
        if lock >= 0 { _ = flock(lock, LOCK_UN); lock = -1 }
        for node in nodes.reversed() { Darwin.close(node.descriptor) }
        nodes.removeAll(); directories.removeAll()
    }
    static func prepare(binding: DesktopReviewBuildBinding, root: URL, beforeHash: @Sendable () -> Void) throws -> DesktopReviewResources {
        let result = DesktopReviewResources(binding: binding, root: root)
        do { try result.prepare(beforeHash: beforeHash); return result } catch { result.close(); throw error }
    }
    private func prepare(beforeHash: @Sendable () -> Void) throws {
        guard binding.reviewBundleIdentifier == DesktopReviewScope.bundleIdentifier,
              binding.fixtureBundleIdentifier == DesktopReviewScope.fixtureBundleIdentifier,
              root.isFileURL, root.deletingLastPathComponent().path == binding.rootParent,
              root.lastPathComponent.hasPrefix("KeyDock-DesktopReview-"),
              let rootID = UUID(uuidString: String(root.lastPathComponent.dropFirst("KeyDock-DesktopReview-".count))),
              validHash(binding.fixtureBinarySHA256), validHash(binding.fixtureInfoSHA256) else { throw DesktopReviewError.invalidScope }
        let rootFD = try directory(root.path, privateOwned: true)
        let markerFD = try file(parent: rootFD, name: "review-session.json", privateOwned: true, maximum: 4096)
        let body = try read(markerFD, maximum: 4096)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard Set(object?.keys.map { $0 } ?? []) == ["schemaVersion", "rootID", "reviewBundleIdentifier", "fixturePID", "fixtureLaunchTime"] else { throw DesktopReviewError.invalidScope }
        marker = try JSONDecoder().decode(DesktopReviewMarker.self, from: body)
        guard marker.schemaVersion == 1, marker.rootID == rootID, marker.reviewBundleIdentifier == binding.reviewBundleIdentifier,
              marker.fixturePID > 1, marker.fixtureLaunchTime.isFinite, marker.fixtureLaunchTime > 0 else { throw DesktopReviewError.invalidScope }
        let lockFD = openat(rootFD, "review-owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard lockFD >= 0 else { throw DesktopReviewError.io(errno) }
        do { try addFile(lockFD, parent: rootFD, name: "review-owner.lock", privateOwned: true, maximum: 0) }
        catch { Darwin.close(lockFD); throw error }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw DesktopReviewError.alreadyOwned }; lock = lockFD
        let appFD = try directory(binding.fixtureAppPath)
        let contents = try directory(binding.fixtureAppPath + "/Contents")
        _ = appFD
        let infoFD = try file(parent: contents, name: "Info.plist", maximum: 65_536)
        let infoData = try read(infoFD, maximum: 65_536)
        guard digest(infoData) == binding.fixtureInfoSHA256,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == binding.fixtureBundleIdentifier,
              info["CFBundleExecutable"] as? String == DesktopReviewScope.fixtureExecutableName else { throw DesktopReviewError.invalidScope }
        let binaryFD = try file(parent: try directory(binding.fixtureAppPath + "/Contents/MacOS"), name: DesktopReviewScope.fixtureExecutableName, maximum: 67_108_864)
        beforeHash()
        guard try hash(binaryFD, maximum: 67_108_864) == binding.fixtureBinarySHA256 else { throw DesktopReviewError.invalidScope }
        if mkdirat(rootFD, "Data", mode_t(0o700)) != 0 && errno != EEXIST { throw DesktopReviewError.io(errno) }
        dataFD = try directory(dataDirectory.path, privateOwned: true)
        let configFD = openat(dataFD, "configuration.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if configFD >= 0 {
            defer { Darwin.close(configFD) }
            try validateFile(configFD, privateOwned: true, maximum: 65_536)
            configuration = try read(configFD, maximum: 65_536)
            var identity = stat()
            guard fstat(configFD, &identity) == 0 else { throw DesktopReviewError.io(errno) }
            expectedConfigurationIdentity = .init(identity)
        } else if errno != ENOENT { throw DesktopReviewError.invalidScope }
        let name = ".review-session-" + UUID().uuidString
        guard mkdirat(dataFD, name, mode_t(0o700)) == 0 else { throw DesktopReviewError.io(errno) }
        sessionDirectory = dataDirectory.appendingPathComponent(name, isDirectory: true)
        _ = try directory(sessionDirectory.path, privateOwned: true)
        guard isCurrent() else { throw DesktopReviewError.invalidScope }
    }
    func isCurrent() -> Bool {
        validityLock.lock(); defer { validityLock.unlock() }
        guard !invalidated else { return false }
        let valid = identitiesAreCurrent()
        if !valid { invalidated = true }
        return valid
    }
    private func identitiesAreCurrent() -> Bool {
        for node in nodes {
            let reason: DesktopReviewInvalidation = node.directory ? .directoryIdentityChanged :
                (node.name == "review-session.json" ? .markerMetadataChanged : (node.name == "review-owner.lock" ? .ownerLockMetadataChanged : .boundAppMetadataChanged))
            var original = stat()
            guard fstat(node.descriptor, &original) == 0, node.identity.matches(.init(original), directory: node.directory) else { return failed(reason) }
            var current = stat()
            let valid = fstatat(node.parent < 0 ? AT_FDCWD : node.parent, node.name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                node.identity.matches(.init(current), directory: node.directory)
            if !valid { return failed(reason) }
        }
        do { guard try configurationIdentity() == expectedConfigurationIdentity else { return failed(.configurationIdentityChanged) } }
        catch { return failed(.configurationIdentityChanged) }
        guard clipboardFD < 0 || clipboardStorageIsCurrent() else { return failed(.clipboardStorageChanged) }
        return true
    }
    func prepareClipboardStorage() throws {
        if clipboardFD >= 0 {
            guard clipboardStorageIsCurrent() else { throw DesktopReviewError.invalidScope }; return
        }
        guard isCurrent(), validClipboardSidecars() else { throw DesktopReviewError.invalidScope }
        var existing = stat()
        if fstatat(dataFD, "clipboard.sqlite", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard validMutableClipboardFile(existing) else { throw DesktopReviewError.invalidScope }
        } else {
            guard errno == ENOENT, !["clipboard.sqlite-journal", "clipboard.sqlite-wal", "clipboard.sqlite-shm"].contains(where: {
                var s = stat(); return fstatat(dataFD, $0, &s, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
            }) else { throw DesktopReviewError.invalidScope }
        }
        let fd = openat(dataFD, "clipboard.sqlite", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw DesktopReviewError.invalidScope }
        do {
            try validateFile(fd, privateOwned: true, maximum: 268_435_456)
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & 0o777 == 0o600 else { throw DesktopReviewError.invalidScope }
            clipboardIdentity = .init(s); clipboardFD = fd
        } catch { Darwin.close(fd); throw error }
        guard clipboardStorageIsCurrent() else { throw DesktopReviewError.invalidScope }
    }
    private func validClipboardSidecars() -> Bool {
        for name in ["clipboard.sqlite-journal", "clipboard.sqlite-wal", "clipboard.sqlite-shm"] {
            var s = stat()
            if fstatat(dataFD, name, &s, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }; return false
            }
            guard validMutableClipboardFile(s) else { return false }
        }
        return true
    }
    private func validMutableClipboardFile(_ s: stat) -> Bool {
        s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && s.st_uid == getuid() &&
            s.st_mode & 0o777 == 0o600 && s.st_nlink == 1 && s.st_size >= 0 && s.st_size <= 268_435_456
    }
    private func clipboardStorageIsCurrent() -> Bool {
        guard let identity = clipboardIdentity else { return false }
        var held = stat(), entry = stat()
        // SQLite使用进程级POSIX锁；不可在连接存活时为复查反复open／close同一inode。
        return fstat(clipboardFD, &held) == 0 && validMutableClipboardFile(held) &&
            fstatat(dataFD, "clipboard.sqlite", &entry, AT_SYMLINK_NOFOLLOW) == 0 && validMutableClipboardFile(entry) &&
            identity.matches(.init(held), directory: true) && identity.matches(.init(entry), directory: true) && validClipboardSidecars()
    }
    func writeConfiguration(_ data: Data) throws {
        guard data.count <= 65_536 else { throw DesktopReviewError.invalidScope }
        validityLock.lock(); defer { validityLock.unlock() }
        guard !invalidated, identitiesAreCurrent() else { invalidated = true; throw DesktopReviewError.invalidScope }
        let name = ".review-config-" + UUID().uuidString
        let fd = openat(dataFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw DesktopReviewError.io(errno) }
        defer { Darwin.close(fd); _ = unlinkat(dataFD, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw DesktopReviewError.io(errno) }; offset += written
            }
        }
        guard fsync(fd) == 0 else { throw DesktopReviewError.io(errno) }
        guard identitiesAreCurrent() else { invalidated = true; throw DesktopReviewError.invalidScope }
        guard renameat(dataFD, name, dataFD, "configuration.json") == 0, fsync(dataFD) == 0 else { throw DesktopReviewError.invalidScope }
        var replacement = stat()
        guard fstat(fd, &replacement) == 0 else { throw DesktopReviewError.io(errno) }
        expectedConfigurationIdentity = .init(replacement)
    }
    private func configurationIdentity() throws -> ReviewFileIdentity? {
        var s = stat()
        if fstatat(dataFD, "configuration.json", &s, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw DesktopReviewError.invalidScope
        }
        guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_uid == getuid(), s.st_mode & 0o077 == 0,
              s.st_nlink == 1, s.st_size >= 0, s.st_size <= 65_536 else { throw DesktopReviewError.invalidScope }
        return .init(s)
    }
    private func directory(_ path: String, privateOwned: Bool = false) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else { throw DesktopReviewError.invalidScope }
        let parts = path.split(separator: "/").map(String.init)
        // Foundation标准化会把真实/private/var路径改写成含链接的/var；这里只做词法检查。
        guard path == "/" + parts.joined(separator: "/"), parts.count <= 64,
              !parts.contains(".."), !parts.contains(".") else { throw DesktopReviewError.invalidScope }
        if directories["/"] == nil {
            let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw DesktopReviewError.io(errno) }
            var s = stat(); guard fstat(fd, &s) == 0 else { Darwin.close(fd); throw DesktopReviewError.io(errno) }
            nodes.append(.init(descriptor: fd, parent: -1, name: "/", directory: true, identity: .init(s))); directories["/"] = fd
        }
        var current = "/", parent = directories["/"]!
        for part in parts {
            current = current == "/" ? "/" + part : current + "/" + part
            if let existing = directories[current] { parent = existing; continue }
            let fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw DesktopReviewError.invalidScope }
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { Darwin.close(fd); throw DesktopReviewError.invalidScope }
            nodes.append(.init(descriptor: fd, parent: parent, name: part, directory: true, identity: .init(s)))
            directories[current] = fd; parent = fd
        }
        if privateOwned {
            var s = stat()
            guard fstat(parent, &s) == 0, s.st_uid == getuid(), s.st_mode & 0o077 == 0 else { throw DesktopReviewError.invalidScope }
        }
        return parent
    }
    private func file(parent: Int32, name: String, privateOwned: Bool = false, maximum: Int) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DesktopReviewError.invalidScope }
        do { try addFile(fd, parent: parent, name: name, privateOwned: privateOwned, maximum: maximum); return fd }
        catch { Darwin.close(fd); throw error }
    }
    private func addFile(_ fd: Int32, parent: Int32, name: String, privateOwned: Bool, maximum: Int) throws {
        try validateFile(fd, privateOwned: privateOwned, maximum: maximum)
        var s = stat(); guard fstat(fd, &s) == 0 else { throw DesktopReviewError.io(errno) }
        nodes.append(.init(descriptor: fd, parent: parent, name: name, directory: false, identity: .init(s)))
    }
    private func validateFile(_ fd: Int32, privateOwned: Bool, maximum: Int) throws {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_nlink == 1, s.st_uid == getuid(), s.st_mode & 0o022 == 0,
              s.st_size >= 0, s.st_size <= maximum,
              !privateOwned || (s.st_uid == getuid() && s.st_mode & 0o077 == 0) else { throw DesktopReviewError.invalidScope }
    }
    private func read(_ fd: Int32, maximum: Int) throws -> Data {
        var result = Data()
        _ = try consume(fd, maximum: maximum) { result.append($0) }; return result
    }
    private func hash(_ fd: Int32, maximum: Int) throws -> String {
        var value = SHA256()
        _ = try consume(fd, maximum: maximum) { value.update(data: $0) }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func consume(_ fd: Int32, maximum: Int, receive: (Data) -> Void) throws -> Int {
        var before = stat(); guard fstat(fd, &before) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw DesktopReviewError.invalidScope }
        var total = 0, bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DesktopReviewError.io(errno) }
            if count == 0 { break }
            total += count; guard total <= maximum else { throw DesktopReviewError.invalidScope }
            receive(Data(bytes.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, ReviewFileIdentity(before) == ReviewFileIdentity(after) else { throw DesktopReviewError.invalidScope }
        return total
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}

@MainActor public final class DisabledClipboardCaptureSource: ClipboardCaptureSource {
    public init() {}
    public var changeCount: Int { 0 }
    public var availableTypes: [String] { [] }
    public var sourceApplication: String? { nil }
    public func readText() -> String? { nil }
}
