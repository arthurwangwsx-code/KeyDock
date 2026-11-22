import Foundation
import CoreServices
import Darwin

public enum ApplicationDirectoryObserverError: Error { case invalidRoots, unavailable }

/// 只观察调用方给定的有限目录；事件仅表示索引失效，不读取路径正文或历史。
public final class ApplicationDirectoryObserver: Sendable {
    let watchedDirectories: [URL]
    private let lifetime: ApplicationDirectoryStreamLifetime

    public init(roots: [URL], onInvalidation: @escaping @MainActor @Sendable () -> Void) throws {
        guard !roots.isEmpty, roots.count <= 16, roots.allSatisfy(\.isFileURL) else {
            throw ApplicationDirectoryObserverError.invalidRoots
        }
        var paths = Set<String>(), parents = Set<String>()
        for root in roots {
            let requested = root.standardizedFileURL
            var candidate = requested
            var isDirectory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                let parent = candidate.deletingLastPathComponent()
                guard parent != candidate else { throw ApplicationDirectoryObserverError.invalidRoots }
                candidate = parent
            }
            let missing = candidate != requested
            candidate = candidate.resolvingSymlinksInPath()
            if missing {
                // 最近父目录只观察自身entry，不能为缺失~/Applications递归观察整个Home。
                parents.insert(candidate.path)
            } else {
                let volume = try candidate.resourceValues(forKeys: [.volumeURLKey]).volume
                guard candidate.path != "/", candidate.path != "/Volumes", candidate != volume?.resolvingSymlinksInPath() else {
                    throw ApplicationDirectoryObserverError.invalidRoots
                }
                paths.insert(candidate.path)
            }
        }
        watchedDirectories = paths.union(parents).sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        lifetime = try ApplicationDirectoryStreamLifetime(paths: paths.sorted(), parents: parents.sorted(), state: ApplicationDirectorySignal(onInvalidation))
    }
    public func stop() { lifetime.stop() }
}

/// stream持有context；排队的主线程信号也持有它，避免释放后使用。
final class ApplicationDirectorySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let callback: @MainActor @Sendable () -> Void
    init(_ callback: @escaping @MainActor @Sendable () -> Void) { self.callback = callback }
    func deactivate() { lock.withLock { active = false } }
    private var isActive: Bool { lock.withLock { active } }
    func enqueue() {
        Task { @MainActor [self] in
            guard isActive else { return }
            callback()
        }
    }
}

/// stream生命周期与MainActor对象分离，最终引用在任意线程释放也能安全清理。
private final class ApplicationDirectoryStreamLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var parentSources: [any DispatchSourceFileSystemObject] = []
    private let state: ApplicationDirectorySignal
    private let queue = DispatchQueue(label: "KeyDock.ApplicationDirectoryObserver", qos: .utility)
    init(paths: [String], parents: [String], state: ApplicationDirectorySignal) throws {
        self.state = state
        do {
            if !paths.isEmpty { stream = try createDirectoryStream(paths: paths, state: state, queue: queue) }
            for path in parents { parentSources.append(try createParentEntrySource(path: path, state: state, queue: queue)) }
        } catch { stop(); throw error }
    }
    func stop() {
        lock.withLock {
            state.deactivate()
            if let stream {
                self.stream = nil
                FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            }
            for source in parentSources { source.cancel() }
            parentSources.removeAll()
        }
    }
    deinit { stop() }
}

// C回调必须在非隔离文件作用域声明，避免继承init的MainActor而在后台触发断言。
private func retainDirectorySignal(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let info else { return nil }
    _ = Unmanaged<ApplicationDirectorySignal>.fromOpaque(info).retain()
    return info
}
private func releaseDirectorySignal(_ info: UnsafeRawPointer?) {
    if let info { Unmanaged<ApplicationDirectorySignal>.fromOpaque(info).release() }
}
private func receiveDirectoryEvents(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard count > 0, let info else { return }
    // RootChanged、Mount/Unmount、丢事件等一律失效；不解引用事件路径。
    Unmanaged<ApplicationDirectorySignal>.fromOpaque(info).takeUnretainedValue().enqueue()
}

private func createDirectoryStream(paths: [String], state: ApplicationDirectorySignal, queue: DispatchQueue) throws -> FSEventStreamRef {
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(),
        retain: retainDirectorySignal, release: releaseDirectorySignal, copyDescription: nil)
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
    guard let stream = FSEventStreamCreate(nil, receiveDirectoryEvents, &context, paths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else { throw ApplicationDirectoryObserverError.unavailable }
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
        FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        throw ApplicationDirectoryObserverError.unavailable
    }
    return stream
}

private func createParentEntrySource(path: String, state: ApplicationDirectorySignal, queue: DispatchQueue) throws -> any DispatchSourceFileSystemObject {
    let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw ApplicationDirectoryObserverError.unavailable }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
    source.setEventHandler { state.enqueue() }
    // fd只由取消handler关闭；排队事件被同一个state gate拒绝。
    source.setCancelHandler { _ = close(descriptor) }
    source.resume()
    return source
}
