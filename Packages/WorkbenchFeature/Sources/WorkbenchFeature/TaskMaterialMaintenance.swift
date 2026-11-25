import Foundation

extension TaskMaterialStore {
    func clear() -> TaskMaterialMutationReport {
        fence.invalidateContent(); issued.removeAll()
        do {
            guard let files = try files(create: false) else { return .init() }
            // 明确清除全部时可替换坏的无正文control；仍不跟随不安全目录项。
            let identity = try files.identity(TaskMaterialFiles.controlName)
            let intent = TaskMaterialDeletionIntent(id: UUID(), all: true, keys: [], targets: [])
            let next = TaskMaterialControl(formatVersion: 1, epoch: UUID(), deletion: intent)
            try persist(next, replacing: identity, files: files)
            return performDeletion(files)
        } catch { return failedReport(error) }
    }

    func delete(_ handle: TaskMaterialHandle) -> TaskMaterialMutationReport {
        fence.invalidateContent(); issued.removeAll()
        do {
            guard let files = try files(create: false), let current = try files.readHeader(handle.key) else { throw TaskMaterialError.missing }
            guard current.version == handle.version, current.fileIdentity == handle.fileIdentity,
                  current.headerSHA256 == handle.headerSHA256 else { throw TaskMaterialError.changed }
            let state = try control(files)
            guard state.value.pendingWrite?.key != handle.key,
                  !(try files.names()).contains(where: { TaskMaterialNames.temporaryKey($0) == handle.key || TaskMaterialNames.isControlTemporary($0) }) else {
                throw TaskMaterialError.recoveryRequired
            }
            let target = TaskMaterialRemovalTarget(key: handle.key, version: handle.version)
            let intent = try merged(state.value.deletion, addingKeys: [], addingTarget: target)
            var next = state.value; next.deletion = intent
            try persist(next, replacing: state.identity, files: files)
            return performDeletion(files)
        } catch { return failedReport(error, keys: [handle.key]) }
    }

    /// history清除传稳定出生key；不会据过期的全量owner集合清掉后来新增的材料。
    func clearOwners(_ keys: Set<TaskMaterialKey>) -> TaskMaterialMutationReport {
        fence.invalidateContent(); issued.removeAll()
        do {
            guard let files = try files(create: false) else { return .init() }
            let state = try control(files), names = try files.names()
            guard !names.contains(where: TaskMaterialNames.isControlTemporary) else { throw TaskMaterialError.recoveryRequired }
            let present = Set(names.compactMap(TaskMaterialNames.key))
            var selected = keys.intersection(present)
            if let pending = state.value.pendingWrite, keys.contains(pending.key) { selected.insert(pending.key) }
            guard selected.count <= 200 else { throw TaskMaterialError.capacity }
            guard !selected.isEmpty || state.value.deletion != nil else { return .init() }
            let intent = try merged(state.value.deletion, addingKeys: selected, addingTarget: nil)
            var next = state.value; next.deletion = intent
            if let pending = next.pendingWrite, intent.covers(pending.key) { next.pendingWrite = nil }
            try persist(next, replacing: state.identity, files: files)
            return performDeletion(files)
        } catch { return failedReport(error, keys: keys) }
    }

    func resumeDeletion() -> TaskMaterialMutationReport {
        do {
            guard let files = try files(create: false), try control(files).value.deletion != nil else { return .init() }
            fence.invalidateContent(); issued.removeAll()
            return performDeletion(files)
        } catch { return failedReport(error) }
    }

    func maintain(_ inventory: TaskMaterialInventory, validOwners: Set<TaskMaterialKey>) -> TaskMaterialMutationReport {
        do {
            let time = try now()
            guard let files = try files(create: false) else { return .init() }
            if try control(files).value.deletion != nil { return resumeDeletion() }
            var targets: [TaskMaterialRemovalTarget] = []
            for candidate in inventory.handles where candidate.header.expiresAt <= time || !validOwners.contains(candidate.key) {
                guard let current = try files.readHeader(candidate.key), current.version == candidate.version,
                      current.fileIdentity == candidate.fileIdentity else { continue }
                targets.append(.init(key: current.key, version: current.version))
            }
            guard !targets.isEmpty else { return .init() }
            fence.invalidateContent(); issued.removeAll()
            let state = try control(files)
            guard state.value.pendingWrite == nil else { throw TaskMaterialError.recoveryRequired }
            var next = state.value
            next.deletion = .init(id: UUID(), all: false, keys: [], targets: targets)
            try persist(next, replacing: state.identity, files: files)
            return performDeletion(files)
        } catch { return failedReport(error) }
    }

    private func merged(_ prior: TaskMaterialDeletionIntent?, addingKeys keys: Set<TaskMaterialKey>, addingTarget target: TaskMaterialRemovalTarget?) throws -> TaskMaterialDeletionIntent {
        if prior?.all == true { return prior! }
        let selected = Set(prior?.keys ?? []).union(keys)
        var targets = Dictionary(uniqueKeysWithValues: (prior?.targets ?? []).map { ($0.key, $0) })
        if let target, !selected.contains(target.key) { targets[target.key] = target }
        for key in selected { targets[key] = nil }
        let value = TaskMaterialDeletionIntent(id: UUID(), all: false,
            keys: selected.sorted { $0.fileName < $1.fileName }, targets: targets.values.sorted { $0.key.fileName < $1.key.fileName })
        guard value.validates() else { throw TaskMaterialError.capacity }
        return value
    }

    private func performDeletion(_ files: TaskMaterialFiles) -> TaskMaterialMutationReport {
        var report = TaskMaterialMutationReport()
        do {
            let state = try control(files)
            guard let intent = state.value.deletion else { return report }
            report.pendingDeletion = true
            for name in try files.names() where name != TaskMaterialFiles.lockName && name != TaskMaterialFiles.controlName {
                guard scoped(name, intent: intent) else { continue }
                do {
                    guard TaskMaterialNames.isManaged(name) else { throw TaskMaterialError.unsafeEntry }
                    if let key = TaskMaterialKey.fromFileName(name), let target = intent.targets.first(where: { $0.key == key }),
                       !intent.keys.contains(key), !intent.all {
                        guard let header = try files.readHeader(key), header.version == target.version else { throw TaskMaterialError.changed }
                    }
                    if TaskMaterialNames.temporaryKey(name) != nil, !intent.all, !intent.keys.contains(TaskMaterialNames.temporaryKey(name)!) {
                        throw TaskMaterialError.recoveryRequired
                    }
                    guard let identity = try files.identity(name) else { continue }
                    try files.remove(name, expected: identity); report.removedNames.insert(name)
                } catch {
                    report.failedNames.insert(name); report.failure = materialError(error)
                }
            }
            report.remainingNames = Set(try files.names().filter { $0 != TaskMaterialFiles.lockName && $0 != TaskMaterialFiles.controlName && scoped($0, intent: intent) })
            report.didInspectRemaining = true
            if report.remainingNames.isEmpty, report.failure == nil {
                try files.synchronizeDirectory()
                var next = state.value; next.deletion = nil
                try persist(next, replacing: state.identity, files: files)
                report.pendingDeletion = false
            }
        } catch { report.failure = materialError(error); report.pendingDeletion = true }
        return report
    }

    private func scoped(_ name: String, intent: TaskMaterialDeletionIntent) -> Bool {
        if intent.all { return true }
        guard let key = TaskMaterialNames.key(name) else { return false }
        return intent.covers(key)
    }
    func materialError(_ error: any Error) -> TaskMaterialError { error as? TaskMaterialError ?? .unavailable }
    private func failedReport(_ error: any Error, keys: Set<TaskMaterialKey>? = nil) -> TaskMaterialMutationReport {
        var report = TaskMaterialMutationReport(failure: materialError(error))
        if let storage, let names = try? storage.names() {
            report.didInspectRemaining = true
            report.remainingNames = Set(names.filter { name in
                guard name != TaskMaterialFiles.lockName, name != TaskMaterialFiles.controlName else { return false }
                if let keys { return TaskMaterialNames.key(name).map(keys.contains) ?? false }
                return true
            })
            report.pendingDeletion = (try? control(storage).value.deletion != nil) ?? false
        }
        return report
    }
}
