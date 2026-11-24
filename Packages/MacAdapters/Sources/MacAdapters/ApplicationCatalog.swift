import Foundation
import AppKit
import CommandCore

public enum ApplicationCatalogError: Error { case inaccessibleRoot, unavailable }

/// 目录身份用于拒绝移走、卸载或同路径替换后的旧结果；不宣称是代码签名验证。
public struct ApplicationReference: Equatable, Sendable {
    public let item: CommandItem
    let device: UInt64
    let inode: UInt64
    let createdAt: Date?
    let bundleIdentifier: String?

    public func matchesCurrentItem() -> Bool {
        guard let current = FileSystemApplicationScanner.reference(at: URL(fileURLWithPath: item.payload)) else { return false }
        return device == current.device && inode == current.inode && createdAt == current.createdAt && bundleIdentifier == current.bundleIdentifier
    }
}

public protocol ApplicationScanning: Sendable {
    func scan() async throws -> [ApplicationReference]
}

public struct FileSystemApplicationScanner: ApplicationScanning {
    private struct PhysicalIdentity: Hashable { let device: UInt64; let inode: UInt64; let createdAt: Date? }
    public static var defaultRoots: [URL] { ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    public let roots: [URL]
    public init(roots: [URL] = Self.defaultRoots) { self.roots = roots }
    public func scan() async throws -> [ApplicationReference] {
        let roots = roots
        let worker = Task.detached(priority: .utility) { try Self.scan(roots: roots) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func scan(roots: [URL]) throws -> [ApplicationReference] {
        guard roots.count <= 16, roots.allSatisfy(\.isFileURL) else { throw ApplicationCatalogError.inaccessibleRoot }
        var records: [PhysicalIdentity: ApplicationReference] = [:]
        for root in roots {
            try Task.checkCancellation()
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path != "/", canonical.path != "/Volumes" else { throw ApplicationCatalogError.inaccessibleRoot }
            do {
                let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .volumeURLKey])
                guard values.isDirectory == true else { continue }
                guard canonical != values.volume?.resolvingSymlinksInPath() else { throw ApplicationCatalogError.inaccessibleRoot }
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code) { continue }
                throw ApplicationCatalogError.inaccessibleRoot
            }
            var enumerationFailed = false
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw ApplicationCatalogError.inaccessibleRoot }
            for case let url as URL in entries {
                try Task.checkCancellation()
                guard url.pathExtension.lowercased() == "app" else { continue }
                entries.skipDescendants()
                if let record = reference(at: url) {
                    let identity = PhysicalIdentity(device: record.device, inode: record.inode, createdAt: record.createdAt)
                    if let previous = records[identity], previous.item.payload < record.item.payload { continue }
                    records[identity] = record
                }
            }
            if enumerationFailed { throw ApplicationCatalogError.inaccessibleRoot }
        }
        return records.values.sorted { $0.item.id < $1.item.id }
    }
    static func reference(at original: URL) -> ApplicationReference? {
        let url = original.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber,
              let info = dictionary(at: url.appendingPathComponent("Contents/Info.plist")), info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"), !executable.contains("\0"),
              manager.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + executable).path) else { return nil }
        var name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        let resources = url.appendingPathComponent("Contents/Resources")
        let localizations = ((try? manager.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }
        for language in Bundle.preferredLocalizations(from: localizations) {
            if let localized = dictionary(at: resources.appendingPathComponent(language + ".lproj/InfoPlist.strings")),
               let display = localized["CFBundleDisplayName"] as? String ?? localized["CFBundleName"] as? String, !display.isEmpty { name = display; break }
        }
        let identifier = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let createdAt = attributes[.creationDate] as? Date
        let revision = "\(device.uint64Value).\(inode.uint64Value).\(createdAt?.timeIntervalSinceReferenceDate ?? 0)|" + (identifier ?? "")
        let item = CommandItem(id: "app." + url.path, title: name, subtitle: url.path,
            keywords: [url.lastPathComponent, info["CFBundleName"] as? String ?? "", identifier ?? ""], kind: .application, payload: url.path, objectRevision: revision)
        return .init(item: item, device: device.uint64Value, inode: inode.uint64Value, createdAt: createdAt, bundleIdentifier: identifier)
    }
    private static func dictionary(at url: URL) -> [String: Any]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// 搜索始终读取缓存；文件事件合并后在后台重扫，旧扫描和停止后的结果均不得发布。
@MainActor public final class ApplicationCatalog {
    public typealias ObservationFactory = @Sendable ([URL], @escaping @MainActor @Sendable () -> Void) throws -> ApplicationDirectoryObserver?
    public var onChange: (@MainActor ([CommandItem]) -> Void)?
    public var onFailure: (@MainActor () -> Void)?
    public private(set) var items: [CommandItem] = []
    private let scanner: any ApplicationScanning
    private let roots: [URL]
    private var references: [String: ApplicationReference] = [:]
    private var observer: ApplicationCatalogObservation?
    private let observationFactory: ObservationFactory
    private let workspaceCenter: @Sendable () -> NotificationCenter
    private var observationTask: Task<Void, Never>?
    private var observationGeneration: UInt64 = 0
    private var observing = false
    private var running = false
    private var generation: UInt64 = 0
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var refreshedAt: ContinuousClock.Instant?

    public init(scanner: (any ApplicationScanning)? = nil, roots: [URL] = FileSystemApplicationScanner.defaultRoots,
                observationFactory: @escaping ObservationFactory = { try ApplicationDirectoryObserver(roots: $0, onInvalidation: $1) },
                workspaceCenter: @escaping @Sendable () -> NotificationCenter = { NSWorkspace.shared.notificationCenter }) {
        self.scanner = scanner ?? FileSystemApplicationScanner(roots: roots); self.roots = roots
        self.observationFactory = observationFactory; self.workspaceCenter = workspaceCenter
    }
    public func start(observing: Bool = true) {
        if observing && !self.observing {
            self.observing = true
            if running { refresh() } // 观察就绪后重新扫描，覆盖初始缓存到监听建立之间的变化。
        }
        guard !running else { return }
        running = true; refresh()
    }
    public func stop() {
        running = false; observing = false; generation &+= 1
        observationGeneration &+= 1; observationTask?.cancel(); observationTask = nil
        if let previous = observer { Task.detached(priority: .utility) { previous.stop() } }; observer = nil
        debounceTask?.cancel(); debounceTask = nil; scanTask?.cancel(); scanTask = nil
    }
    public func refreshIfStale(maxAge: Duration = .seconds(30)) {
        guard running, scanTask == nil else { return }
        if let refreshedAt, refreshedAt.duration(to: .now) < maxAge { return }
        refresh()
    }
    public func invalidate() {
        guard running else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.refresh()
        }
    }
    public func refresh() {
        guard running else { return }
        debounceTask?.cancel(); debounceTask = nil
        generation &+= 1; let request = generation, scanner = scanner
        scanTask?.cancel()
        let observation = observing ? armObserver() : nil
        scanTask = Task { [weak self] in
            do {
                await observation?.value
                try Task.checkCancellation()
                let records = try await scanner.scan()
                guard let self, self.running, self.generation == request, !Task.isCancelled else { return }
                self.scanTask = nil; self.refreshedAt = .now
                self.references = Dictionary(records.map { ($0.item.payload, $0) }, uniquingKeysWith: { first, _ in first })
                self.items = records.map(\.item); self.onChange?(self.items)
            } catch {
                guard let self, self.running, self.generation == request, !Task.isCancelled else { return }
                self.scanTask = nil; self.onFailure?()
            }
        }
    }
    public func validatedURL(for item: CommandItem) async throws -> URL {
        guard running, item.kind == .application, let reference = references[item.payload],
              reference.item.id == item.id, let revision = item.objectRevision,
              revision == reference.item.objectRevision else { throw ApplicationCatalogError.unavailable }
        let worker = Task.detached(priority: .userInitiated) { reference.matchesCurrentItem() }
        let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard matches, running, !Task.isCancelled, references[item.payload]?.item.objectRevision == revision else { throw ApplicationCatalogError.unavailable }
        return URL(fileURLWithPath: item.payload)
    }
    @discardableResult private func armObserver() -> Task<Void, Never>? {
        observationTask?.cancel(); observationGeneration &+= 1
        let request = observationGeneration, previous = observer, roots = roots, factory = observationFactory, workspaceCenter = workspaceCenter
        observer = nil
        // 路径解析、卷查询、open及旧stream收尾均不在唤起面板的主线程片段执行。
        let worker = Task.detached(priority: .utility) { [weak self] () throws -> ApplicationCatalogObservation? in
            previous?.stop(); try Task.checkCancellation()
            guard !roots.isEmpty else { return nil }
            let center = workspaceCenter(); try Task.checkCancellation()
            let onInvalidation: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.running, self.observing, self.observationGeneration == request else { return }
                self.invalidate()
            }
            let volumes = ApplicationVolumeObservation(center: center, onInvalidation: onInvalidation)
            let directory: ApplicationDirectoryObserver?, preparationFailed: Bool
            do { directory = try factory(roots, onInvalidation); preparationFailed = false }
            catch { directory = nil; preparationFailed = true }
            let candidate = ApplicationCatalogObservation(directory: directory, volumes: volumes, directoryPreparationFailed: preparationFailed)
            if Task.isCancelled { candidate.stop(); throw CancellationError() }
            return candidate
        }
        let task = Task { [weak self] in
            do {
                let candidate = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.running, self.observing, self.observationGeneration == request, !Task.isCancelled else {
                    if let candidate { await Task.detached(priority: .utility) { candidate.stop() }.value }; return
                }
                self.observer = candidate
                if candidate?.directoryPreparationFailed == true { self.onFailure?() }
            } catch {
                guard let self, self.running, self.observationGeneration == request, !Task.isCancelled else { return }
                self.onFailure?() // 唤起时TTL刷新仍可用，不扩大监听范围。
            }
        }
        observationTask = task
        return task
    }
}

/// 一个后台准备代次的完整所有权；目录监听失败时仍保留卷通知恢复通道。
private final class ApplicationCatalogObservation: Sendable {
    let directory: ApplicationDirectoryObserver?
    let volumes: ApplicationVolumeObservation
    let directoryPreparationFailed: Bool
    init(directory: ApplicationDirectoryObserver?, volumes: ApplicationVolumeObservation, directoryPreparationFailed: Bool) {
        self.directory = directory; self.volumes = volumes; self.directoryPreparationFailed = directoryPreparationFailed
    }
    func stop() { volumes.stop(); directory?.stop() }
}

/// center和token均由创建时的后台代次持有；清理不重新访问NSWorkspace。
final class ApplicationVolumeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let center: NotificationCenter
    private let state: ApplicationDirectorySignal
    private var tokens: [NSObjectProtocol] = []
    init(center: NotificationCenter, onInvalidation: @escaping @MainActor @Sendable () -> Void) {
        self.center = center; state = ApplicationDirectorySignal(onInvalidation)
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [state] _ in state.enqueue() })
        }
    }
    func stop() {
        lock.withLock {
            state.deactivate()
            for token in tokens { center.removeObserver(token) }
            tokens.removeAll()
        }
    }
    deinit { stop() }
}
