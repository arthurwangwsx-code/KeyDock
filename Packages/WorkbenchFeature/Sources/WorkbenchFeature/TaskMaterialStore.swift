import Foundation
import Darwin

/// 正文独立于InvocationStore；此actor从不打开网络、进程、剪贴板或执行恢复入口。
actor TaskMaterialStore {
    nonisolated let fence: TaskMaterialFence
    let directory: URL
    let policy: TaskMaterialPolicy
    let clock: @Sendable () -> Date
    let fault: TaskMaterialFiles.Fault
    let observeRead: TaskMaterialFiles.ReadObserver
    let storeIdentity = UUID()
    var storage: TaskMaterialFiles?
    var closed = false
    struct Issued: Sendable { let check: TaskMaterialWriteCheck; let previous: TaskMaterialHandle? }
    var issued: [UUID: Issued] = [:]

    init(directory: URL, policy: TaskMaterialPolicy = .init(), fence: TaskMaterialFence = .init(),
         clock: @escaping @Sendable () -> Date = { Date() }, fault: @escaping TaskMaterialFiles.Fault = { _, _, _ in nil },
         observeRead: @escaping TaskMaterialFiles.ReadObserver = { _, _ in }) throws {
        try policy.validate()
        guard directory.isFileURL else { throw TaskMaterialError.unavailable }
        self.directory = directory; self.policy = policy; self.fence = fence
        self.clock = clock; self.fault = fault; self.observeRead = observeRead
    }

    func shutdown() { closed = true; issued.removeAll(); storage = nil }
    func barrier() { issued = issued.filter { $0.value.check.fence == fence.current } }

    func inventory() throws -> TaskMaterialInventory {
        let generation = fence.current.generation
        guard let files = try files(create: false) else { return .init(generation: generation) }
        var result = try scan(files)
        guard fence.current.generation == generation else { throw TaskMaterialError.staleCheck }
        result.generation = generation; return result
    }

    func inspect(_ key: TaskMaterialKey) throws -> TaskMaterialHandle? {
        guard let files = try files(create: false) else { return nil }
        let state = try control(files)
        let handle = try files.readHeader(key)
        if state.value.deletion?.covers(key, version: handle?.version) == true { throw TaskMaterialError.pendingDeletion }
        guard !(try files.names()).contains(where: TaskMaterialNames.isControlTemporary) else { throw TaskMaterialError.recoveryRequired }
        return handle
    }

    func read(_ handle: TaskMaterialHandle, expectedGeneration: UUID) throws -> SelectedTaskMaterial {
        guard fence.current.generation == expectedGeneration else { throw TaskMaterialError.staleCheck }
        guard let files = try files(create: false) else { throw TaskMaterialError.missing }
        let state = try control(files)
        guard state.value.deletion?.covers(handle.key, version: handle.version) != true else { throw TaskMaterialError.pendingDeletion }
        guard !(try files.names()).contains(where: TaskMaterialNames.isControlTemporary) else { throw TaskMaterialError.recoveryRequired }
        guard handle.header.expiresAt > (try now()) else { throw TaskMaterialError.expired }
        let payload = try files.readBody(handle)
        guard fence.current.generation == expectedGeneration else { throw TaskMaterialError.staleCheck }
        return payload
    }

    /// 仅在用户确认保存后调用；预期不存在与预期旧版本不能互相替换。
    func prepareWrite(_ key: TaskMaterialKey, expected: TaskMaterialVersion?) throws -> TaskMaterialWriteCheck {
        let snapshot = fence.current
        guard snapshot.enabled else { throw TaskMaterialError.permissionDenied }
        guard let files = try files(create: true) else { throw TaskMaterialError.unavailable }
        _ = try settlePendingWriteIfSafe(files)
        let state = try control(files), index = try scan(files)
        guard state.value.deletion == nil else { throw TaskMaterialError.pendingDeletion }
        guard state.value.pendingWrite == nil, index.managedTemporaryNames.isEmpty else { throw TaskMaterialError.recoveryRequired }
        guard index.unsafeNames.isEmpty else { throw TaskMaterialError.unsafeEntry }
        let previous = try files.readHeader(key)
        guard previous?.version == expected else { throw TaskMaterialError.changed }
        issued = issued.filter { $0.value.check.fence == snapshot }
        guard issued.count < 64 else { throw TaskMaterialError.capacity }
        guard fence.current == snapshot else { throw TaskMaterialError.permissionDenied }
        let check = TaskMaterialWriteCheck(key: key, expected: expected, storeIdentity: storeIdentity, nonce: UUID(), fence: snapshot)
        issued[check.nonce] = .init(check: check, previous: previous)
        return check
    }

    func save(_ material: SelectedTaskMaterial, using check: TaskMaterialWriteCheck) throws -> TaskMaterialHandle {
        guard check.storeIdentity == storeIdentity else { throw TaskMaterialError.foreignCheck }
        guard let ticket = issued[check.nonce], ticket.check == check else { throw TaskMaterialError.staleCheck }
        issued[check.nonce] = nil
        guard check.fence.enabled, fence.current == check.fence else { throw TaskMaterialError.permissionDenied }
        guard let files = try files(create: false) else { throw TaskMaterialError.missing }
        let state = try control(files), index = try scan(files)
        guard state.value.deletion == nil else { throw TaskMaterialError.pendingDeletion }
        guard state.value.pendingWrite == nil, index.managedTemporaryNames.isEmpty else { throw TaskMaterialError.recoveryRequired }
        guard index.unsafeNames.isEmpty else { throw TaskMaterialError.unsafeEntry }
        guard try files.readHeader(check.key)?.version == check.expected else { throw TaskMaterialError.changed }
        let time = try now(), version: TaskMaterialVersion
        if let previous = check.expected {
            guard previous.revision < UInt64.max else { throw TaskMaterialError.revisionExhausted }
            version = .init(identity: previous.identity, revision: previous.revision + 1)
        } else { version = .init(identity: UUID(), revision: 1) }
        let (bytes, header) = try TaskMaterialFormat.frame(material, key: check.key, version: version, createdAt: time, expiresAt: time + policy.retentionInterval)
        let count = index.handles.count + (ticket.previous == nil ? 1 : 0)
        guard bytes.count <= policy.maximumRecordBytes, count <= policy.maximumCount,
              index.retainedBytes <= policy.maximumTotalBytes - min(bytes.count, policy.maximumTotalBytes),
              bytes.count <= policy.maximumTotalBytes else { throw TaskMaterialError.capacity }
        let pending = TaskMaterialPendingWrite(key: check.key, proposed: version, previous: check.expected,
            payloadSHA256: header.payloadSHA256, fileBytes: bytes.count)
        var intent = state.value; intent.pendingWrite = pending
        try persist(intent, replacing: state.identity, files: files)
        do {
            let fence = self.fence
            try files.writeBody(bytes, key: check.key, expected: ticket.previous?.fileIdentity,
                validate: { guard fence.current == check.fence else { throw TaskMaterialError.permissionDenied } },
                commit: { try fence.commit(if: check.fence, $0) })
            guard let current = try files.readHeader(check.key), current.version == version,
                  current.header.payloadSHA256 == header.payloadSHA256 else { throw TaskMaterialError.durabilityUncertain(5) }
            guard try settlePendingWriteIfSafe(files) else { throw TaskMaterialError.recoveryRequired }
            return current
        } catch {
            // 只同步目录／收口无正文控制记录；绝不重新写正文，也不自动重试保存。
            _ = try? settlePendingWriteIfSafe(files)
            throw error
        }
    }

    struct ControlState: Sendable { let value: TaskMaterialControl; let identity: TaskMaterialFileIdentity? }
    func control(_ files: TaskMaterialFiles) throws -> ControlState {
        if let (bytes, identity) = try files.readControl() { return .init(value: try TaskMaterialControl.decode(bytes), identity: identity) }
        return .init(value: .empty(), identity: nil)
    }
    func persist(_ value: TaskMaterialControl, replacing identity: TaskMaterialFileIdentity?, files: TaskMaterialFiles) throws {
        try files.writeControl(value.encoded(), expected: identity)
    }
    func files(create: Bool) throws -> TaskMaterialFiles? {
        guard !closed else { throw TaskMaterialError.closed }
        if let storage { try storage.requireBoundDirectory(); return storage }
        // 仅当次缺席快探针；不能作为installer安全空库资格，也不影响create的严格祖先检查。
        if !create {
            var info = stat()
            if lstat(directory.path, &info) != 0, errno == ENOENT { return nil }
        }
        do {
            let opened = try TaskMaterialFiles(directory: directory, create: create, fault: fault, observeRead: observeRead)
            storage = opened; return opened
        } catch TaskMaterialError.missing where !create { return nil }
    }
    func now() throws -> TimeInterval {
        let value = clock().timeIntervalSince1970
        guard value.isFinite, value >= 0, (value + policy.retentionInterval).isFinite else { throw TaskMaterialError.invalidClock }
        return value
    }

    func scan(_ files: TaskMaterialFiles) throws -> TaskMaterialInventory {
        let names = try files.names()
        var result = TaskMaterialInventory()
        let state: ControlState?
        do { state = try control(files) }
        catch { state = nil; result.unsafeNames.append(TaskMaterialFiles.controlName); result.pendingDeletion = true }
        result.pendingDeletion = result.pendingDeletion || state?.value.deletion != nil || names.contains(where: TaskMaterialNames.isControlTemporary)
        result.pendingWrite = state?.value.pendingWrite != nil
        for name in names where name != TaskMaterialFiles.lockName && name != TaskMaterialFiles.controlName {
            do {
                guard let identity = try files.identity(name) else { continue }
                let (sum, overflow) = result.retainedBytes.addingReportingOverflow(identity.size)
                result.retainedBytes = overflow ? Int.max : sum
                if let key = TaskMaterialKey.fromFileName(name) {
                    guard identity.size <= policy.maximumRecordBytes, let handle = try files.readHeader(key) else { throw TaskMaterialError.capacity }
                    if state != nil, !names.contains(where: TaskMaterialNames.isControlTemporary),
                       state?.value.deletion?.covers(key, version: handle.version) != true { result.handles.append(handle) }
                } else if TaskMaterialNames.temporaryKey(name) != nil || TaskMaterialNames.isControlTemporary(name) {
                    result.managedTemporaryNames.append(name)
                } else { result.unsafeNames.append(name) }
            } catch { result.unsafeNames.append(name) }
        }
        try files.requireBoundDirectory()
        return result
    }

    /// 无临时文件且当前版本与已确认保存意图一致时，只确认目录状态，不重写／重建正文。
    @discardableResult func settlePendingWriteIfSafe(_ files: TaskMaterialFiles) throws -> Bool {
        let state = try control(files)
        guard let pending = state.value.pendingWrite else { return true }
        let names = try files.names()
        guard !names.contains(where: { TaskMaterialNames.isControlTemporary($0) || TaskMaterialNames.temporaryKey($0) == pending.key }) else { return false }
        let current = try files.readHeader(pending.key)
        let proposedMatches = current.map { $0.version == pending.proposed && $0.fileIdentity.size == pending.fileBytes && $0.header.payloadSHA256 == pending.payloadSHA256 } ?? false
        guard proposedMatches || current?.version == pending.previous else { return false }
        try files.synchronizeDirectory()
        var next = state.value; next.pendingWrite = nil
        try persist(next, replacing: state.identity, files: files)
        return true
    }
}
