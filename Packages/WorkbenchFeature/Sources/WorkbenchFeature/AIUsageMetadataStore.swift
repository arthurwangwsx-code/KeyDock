import Foundation
import Darwin
import ExecutionCore

/// 只管理用量元数据；调用方不得传入提示词、输出、密钥或窗口引用。
struct AIUsageRetentionPolicy: Sendable {
    var retentionInterval: TimeInterval = 90 * 86_400
    var maximumCount: Int = 5_000
    var maximumTotalBytes: UInt64 = 16 * 1_024 * 1_024
    var maximumRecordBytes: Int = 64 * 1_024
}

enum AIUsageMaintenanceTrigger: Sendable { case startup, daily, afterSave, manual, clear }

enum AIUsageStorageProblem: Sendable, Equatable {
    case directoryUnavailable, enumerationFailed, capacityExceeded, storeClosed, maintenanceSuperseded
    case malformedRecord(UUID), oversizedRecord(UUID), unsafeEntry(UUID)
    case readFailed(UUID), deletionFailed(UUID), writeFailed(UUID), expiredIncomingRecord(UUID)
    case budgetRedactionFailed(UUID?), changedCandidate(UUID), deletionUncertain(UUID), duplicateRecordID(UUID)
}

struct AIUsageMaintenanceReport: Sendable {
    let trigger: AIUsageMaintenanceTrigger
    var revision: UInt64 = 0
    var removedIDs: Set<UUID> = []
    var remainingIDs: Set<UUID> = []
    var failedIDs: Set<UUID> = []
    var budgetRedactedIDs: Set<UUID> = []
    var deferredIDs: Set<UUID> = []
    var uncertainRemovedIDs: Set<UUID> = []
    var removedCount = 0
    var removedBytes: UInt64 = 0
    var remainingCount = 0
    var remainingBytes: UInt64 = 0
    var ignoredEntryCount = 0
    var didReadDirectory = false
    var hasFinalInventory = false
    /// 最多保留64个问题详情，总问题数不截断。
    var problems: [AIUsageStorageProblem] = []
    var problemCount = 0
    var isComplete: Bool { didReadDirectory && problemCount == 0 && deferredIDs.isEmpty && uncertainRemovedIDs.isEmpty }
    var onlyDeferred: Bool { didReadDirectory && problemCount == 0 && !deferredIDs.isEmpty && uncertainRemovedIDs.isEmpty }

    fileprivate mutating func add(_ problem: AIUsageStorageProblem, id: UUID? = nil) {
        if problems.count < 64 { problems.append(problem) }
        problemCount += 1
        if let id { failedIDs.insert(id) }
    }
}

struct AIUsageMetadataWriteResult: Sendable {
    let stored: Bool
    let report: AIUsageMaintenanceReport
}

struct AIUsageMetadataReadResult: Sendable {
    let data: Data?
    let problem: AIUsageStorageProblem?
    var revision: UInt64 = 0
}

/// 文件I/O在actor上串行执行，不阻塞MainActor，也不持有Store或窗口。
actor AIUsageMetadataStore {
    nonisolated let revisionFence = AIUsageRevisionFence()
    nonisolated let retentionFence = AIUsageRetentionFence()
    typealias ReportHandler = @Sendable (AIUsageMaintenanceReport) async -> Void
    typealias RemoveEntry = @Sendable (Int32, String) throws -> Void
    typealias PrepareRemoval = @Sendable (Set<UUID>, Bool, [InvocationUsageClearTicket]) async throws -> InvocationUsageRemoval
    typealias SyncDirectory = @Sendable (Int32) throws -> Void

    private let directory: URL
    private let policy: AIUsageRetentionPolicy
    private let clock: @Sendable () -> Date
    private let dailyInterval: Duration
    private var reportHandler: ReportHandler
    private let removeEntry: RemoveEntry
    private let prepareRemoval: PrepareRemoval
    private let syncDirectory: SyncDirectory
    private let beforeFinalInventory: @Sendable (AIUsageMaintenanceTrigger) throws -> Void
    private var dailyTask: Task<Void, Never>?
    private var scheduleGeneration: UInt64 = 0
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var retentionActive = false
    private var pendingClearEntries: [UUID: Entry] = [:]
    private var pendingUnlinks: [UUID: Entry] = [:]
    private var pendingDirectory: (dev_t, ino_t)?
    private var pendingBudgetTickets: [UUID: InvocationUsageClearTicket] = [:]
    private var isClosed = false
    private var isClosing = false

    init(directory: URL, policy: AIUsageRetentionPolicy = .init(),
         clock: @escaping @Sendable () -> Date = { Date() },
         dailyInterval: Duration = .seconds(86_400),
         reportHandler: @escaping ReportHandler = { _ in },
         removeEntry: @escaping RemoveEntry = { descriptor, name in
             guard unlinkat(descriptor, name, 0) == 0 else { throw POSIXFailure.operation }
         },
         prepareRemoval: @escaping PrepareRemoval = { ids, _, _ in .init(approvedIDs: ids) },
         beforeFinalInventory: @escaping @Sendable (AIUsageMaintenanceTrigger) throws -> Void = { _ in },
         syncDirectory: @escaping SyncDirectory = { descriptor in
             guard fsync(descriptor) == 0 else { throw POSIXFailure.operation }
         }) {
        precondition(directory.isFileURL && policy.retentionInterval.isFinite && policy.retentionInterval >= 0)
        precondition(policy.maximumCount > 0 && policy.maximumTotalBytes > 0 && policy.maximumRecordBytes > 0)
        precondition(dailyInterval > .zero)
        self.directory = directory
        self.policy = policy
        self.clock = clock
        self.dailyInterval = dailyInterval
        self.reportHandler = reportHandler
        self.removeEntry = removeEntry
        self.prepareRemoval = prepareRemoval; self.syncDirectory = syncDirectory
        self.beforeFinalInventory = beforeFinalInventory
    }

    deinit { dailyTask?.cancel() }
    var isMaintenanceScheduled: Bool { dailyTask != nil }
    var pendingMutationCount: Int { mutationWaiters.count }

    func setReportHandler(_ handler: @escaping ReportHandler) { reportHandler = handler }

    @discardableResult func start() async -> AIUsageMaintenanceReport {
        guard !isClosing else { return closedReport(.startup) }
        let requestedSchedule = scheduleGeneration
        await enterMutation(); defer { leaveMutation() }
        guard !isClosed else { return closedReport(.startup) }
        guard requestedSchedule == scheduleGeneration else {
            var report = AIUsageMaintenanceReport(trigger: .startup); report.add(.maintenanceSuperseded); return report
        }
        let report = await deliver(await performMaintenance(trigger: .startup))
        if dailyTask == nil, requestedSchedule == scheduleGeneration {
            scheduleGeneration &+= 1
            let generation = scheduleGeneration, interval = dailyInterval
            dailyTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { break }
                    guard !Task.isCancelled else { break }
                    await self?.performDailyMaintenance(generation: generation)
                }
            }
        }
        return report
    }

    /// 只停止定时器；退出收口中的AI任务仍可save，不丢弃终态用量。
    func stop() {
        scheduleGeneration &+= 1
        dailyTask?.cancel()
        dailyTask = nil
    }

    @discardableResult func maintain() async -> AIUsageMaintenanceReport {
        guard !isClosing else { return closedReport(.manual) }
        await enterMutation(); defer { leaveMutation() }
        guard !isClosed else { return closedReport(.manual) }
        return await deliver(await performMaintenance(trigger: .manual))
    }

    @discardableResult func clear() async -> AIUsageMaintenanceReport {
        guard !isClosing else { return closedReport(.clear) }
        await enterMutation(); defer { leaveMutation() }
        guard !isClosed else { return closedReport(.clear) }
        return await deliver(await performMaintenance(trigger: .clear))
    }

    func retryDeferredMaintenance() async {
        guard !isClosing, needsRetry else { return }
        _ = await maintain()
    }

    private var needsRetry: Bool {
        !pendingClearEntries.isEmpty || !pendingUnlinks.isEmpty || !pendingBudgetTickets.isEmpty || hasDeferredMaintenance
    }

    /// worker终态已等待后才关闭；跨actor维护和排队旧请求全部越过同一屏障。
    func close() async {
        stop(); isClosing = true
        await enterMutation(); defer { leaveMutation() }
        guard !isClosed else { return }
        if needsRetry { _ = await deliver(await performMaintenance(trigger: .manual)) }
        isClosed = true
    }
    private func closedReport(_ trigger: AIUsageMaintenanceTrigger) -> AIUsageMaintenanceReport {
        var report = AIUsageMaintenanceReport(trigger: trigger); report.add(.storeClosed); return report
    }
    private var hasDeferredMaintenance = false

    private func enterMutation() async {
        if !mutationActive { mutationActive = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }
    private func leaveMutation() {
        if retentionActive { retentionFence.end(); retentionActive = false }
        if mutationWaiters.isEmpty { mutationActive = false }
        else { mutationWaiters.removeFirst().resume() }
    }
    private func beginRetention() {
        if !retentionActive { retentionFence.begin(); retentionActive = true }
    }
    private func deliver(_ input: AIUsageMaintenanceReport) async -> AIUsageMaintenanceReport {
        var report = input; report.revision = revisionFence.advance()
        if !report.deferredIDs.isEmpty { hasDeferredMaintenance = true }
        else if report.hasFinalInventory { hasDeferredMaintenance = false }
        await reportHandler(report)
        return report
    }

    func read(id: UUID) -> AIUsageMetadataReadResult {
        guard !isClosed else { return .init(data: nil, problem: .storeClosed, revision: revisionFence.current) }
        var result = readImpl(id: id); result.revision = revisionFence.current; return result
    }
    private func readImpl(id: UUID) -> AIUsageMetadataReadResult {
        do {
            guard let descriptor = try openDirectory(create: false) else { return .init(data: nil, problem: nil) }
            defer { Darwin.close(descriptor) }
            let name = id.uuidString + ".json"
            guard let entry = inspect(descriptor, name: name, id: id) else {
                return .init(data: nil, problem: errno == ENOENT ? nil : .readFailed(id))
            }
            guard entry.kind == .valid else { return .init(data: nil, problem: entry.problem) }
            return .init(data: try readRecord(descriptor, entry: entry), problem: nil)
        } catch let error as RecordFailure {
            return .init(data: nil, problem: error == .oversized ? .oversizedRecord(id) : .readFailed(id))
        } catch { return .init(data: nil, problem: .directoryUnavailable) }
    }

    /// 只读逐叶折叠；同时约束枚举、记录、单条及累计读取量，不依赖维护后通常满足预算。
    func readAnalysis(from: Date, to: Date) throws -> AIUsageAnalysisReport {
        guard !isClosed else { throw CocoaError(.fileReadUnknown) }
        let span = to.timeIntervalSince(from)
        guard from.timeIntervalSinceReferenceDate.isFinite, to.timeIntervalSinceReferenceDate.isFinite,
              span.isFinite, span > 0, span <= 90 * 86_400 else { throw CocoaError(.coderReadCorrupt) }
        var accumulator = AIUsageAnalysisAccumulator(from: from, to: to, revision: revisionFence.current, now: clock())
        do {
            guard let descriptor = try openDirectory(create: false) else { return accumulator.finish() }
            defer { Darwin.close(descriptor) }
            let cursor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard cursor >= 0 else { throw POSIXFailure.operation }
            guard let stream = fdopendir(cursor) else { Darwin.close(cursor); throw POSIXFailure.operation }
            defer { closedir(stream) }
            var records = 0, bytes: UInt64 = 0
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let item = readdir(stream) else { if errno != 0 { accumulator.problem() }; break }
                let name = withUnsafePointer(to: item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard accumulator.report.scannedEntries < 10_000 else { accumulator.problem(); break }
                accumulator.entry()
                guard let id = managedID(name) else { continue }
                guard records < min(5_000, policy.maximumCount) else { accumulator.problem(); break }
                records += 1
                guard let entry = inspect(descriptor, name: name, id: id, readHeader: false), entry.kind == .valid else { accumulator.problem(); continue }
                guard bytes <= policy.maximumTotalBytes, entry.size <= policy.maximumTotalBytes - bytes else { accumulator.problem(); break }
                let remaining = min(UInt64(policy.maximumRecordBytes), policy.maximumTotalBytes - bytes)
                var consumed = 0
                do {
                    let data = try readRecord(descriptor, entry: entry, maximumBytes: Int(remaining), observeRead: { consumed += $0 })
                    bytes += UInt64(consumed); accumulator.consume(data, id: id)
                } catch {
                    // 后置身份检查失败仍保留已读字节，不能靠坏文件绕过累计预算。
                    bytes += UInt64(consumed); accumulator.failedRead(bytes: consumed)
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { accumulator.problem() }
        return accumulator.finish()
    }

    /// 保存前先验证，按包含新记录的投影预算逐出旧记录，容量无法满足时拒绝写入。
    func save(id: UUID, data: Data) async -> AIUsageMetadataWriteResult {
        guard !isClosing else { return .init(stored: false, report: closedReport(.afterSave)) }
        await enterMutation(); defer { leaveMutation() }
        guard !isClosed else { return .init(stored: false, report: closedReport(.afterSave)) }
        var report = AIUsageMaintenanceReport(trigger: .afterSave)
        guard data.count <= policy.maximumRecordBytes else {
            report.add(.oversizedRecord(id), id: id)
            return await completeWrite(stored: false, report: report)
        }
        guard let header = decodeHeader(data, id: id) else {
            report.add(.malformedRecord(id), id: id)
            return await completeWrite(stored: false, report: report)
        }
        let now = clock()
        guard header.recordedAt > now.addingTimeInterval(-policy.retentionInterval) else {
            report.add(.expiredIncomingRecord(id), id: id)
            return await completeWrite(stored: false, report: report)
        }
        do {
            guard let descriptor = try openDirectory(create: true) else { throw POSIXFailure.operation }
            defer { Darwin.close(descriptor) }
            var entries = try scan(descriptor, report: &report)
            report.didReadDirectory = true
            let name = id.uuidString + ".json"
            if let target = entries.first(where: { $0.name == name }), !target.isRegular {
                report.add(.unsafeEntry(id), id: id)
                finalize(entries, report: &report)
                return await completeWrite(stored: false, report: report)
            }
            await expire(descriptor, entries: &entries, now: now, report: &report)
            let reserved = Reservation(name: name, size: UInt64(data.count))
            guard await makeRoom(descriptor, entries: &entries, reservation: reserved, report: &report) else {
                synchronizeRemovals(descriptor, report: &report)
                entries = try scan(descriptor, report: &report)
                finalize(entries, report: &report)
                return await completeWrite(stored: false, report: report)
            }
            synchronizeRemovals(descriptor, report: &report)
            var stored = false
            do { try writeRecord(descriptor, name: name, data: data); stored = true }
            catch { report.add(.writeFailed(id), id: id) }
            // 写入失败也可能发生在rename后的fsync：重新盘点，不能虚假声称文件不存在。
            report.ignoredEntryCount = 0
            entries = try scan(descriptor, report: &report)
            reconcilePendingClear(entries)
            finalize(entries, report: &report)
            return await completeWrite(stored: stored, report: report)
        } catch {
            report.add(report.didReadDirectory ? .enumerationFailed : .directoryUnavailable)
            return await completeWrite(stored: false, report: report)
        }
    }

    private func completeWrite(stored: Bool, report: AIUsageMaintenanceReport) async -> AIUsageMetadataWriteResult {
        .init(stored: stored, report: await deliver(report))
    }

    private func performDailyMaintenance(generation: UInt64) async {
        await enterMutation(); defer { leaveMutation() }
        guard !isClosed, generation == scheduleGeneration, dailyTask != nil else { return }
        _ = await deliver(await performMaintenance(trigger: .daily))
    }

    private func performMaintenance(trigger: AIUsageMaintenanceTrigger) async -> AIUsageMaintenanceReport {
        var report = AIUsageMaintenanceReport(trigger: trigger)
        do {
            let descriptor = try openDirectory(create: trigger != .clear)
            defer { if let descriptor { Darwin.close(descriptor) } }
            var entries = try descriptor.map { try scan($0, report: &report) } ?? []
            report.didReadDirectory = true
            if trigger == .clear || !pendingBudgetTickets.isEmpty {
                beginRetention()
                do { _ = try await prepareBudgets([], all: trigger == .clear, report: &report) }
                catch { report.add(.budgetRedactionFailed(nil)); finalize(entries, report: &report); return report }
            }
            guard let descriptor else {
                if !pendingUnlinks.isEmpty { report.add(.directoryUnavailable) }
                report.hasFinalInventory = true
                return report
            }
            if trigger == .clear {
                // 显式清除可删除损坏/超限的普通文件，符号链接和其他文件类型仍保留并报告。
                let candidates = entries.filter(\.isRegular)
                for entry in candidates { pendingClearEntries[entry.id] = entry }
                await deleteCandidates(descriptor, candidates: candidates, entries: &entries, report: &report)
            } else {
                await expire(descriptor, entries: &entries, now: clock(), report: &report)
                _ = await makeRoom(descriptor, entries: &entries, reservation: nil, report: &report)
            }
            synchronizeRemovals(descriptor, report: &report)
            try beforeFinalInventory(trigger)
            entries = try scan(descriptor, report: &report)
            reconcilePendingClear(entries)
            finalize(entries, report: &report)
            report.hasFinalInventory = true
        } catch { report.add(report.didReadDirectory ? .enumerationFailed : .directoryUnavailable) }
        return report
    }

    private struct Header: Decodable { let runID: UUID; let recordedAt: Date }
    private enum EntryKind { case valid, corrupt, oversized, unsafe, unreadable }
    private enum POSIXFailure: Error { case operation }
    private enum RecordFailure: Error { case oversized, changed, read }
    private struct Entry {
        let name: String
        let id: UUID
        let size: UInt64
        let device: dev_t
        let inode: ino_t
        let isRegular: Bool
        let modified: timespec
        let changed: timespec
        var kind: EntryKind
        var recordedAt: Date?
        var problem: AIUsageStorageProblem? {
            switch kind {
            case .valid: nil
            case .corrupt: .malformedRecord(id)
            case .oversized: .oversizedRecord(id)
            case .unsafe: .unsafeEntry(id)
            case .unreadable: .readFailed(id)
            }
        }
    }
    private struct Reservation { let name: String; let size: UInt64 }

    private func decodeHeader(_ data: Data, id: UUID) -> Header? {
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.runID == id,
              header.recordedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return header
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        let path = directory.path
        if create, mkdir(path, 0o700) != 0, errno != EEXIST { throw POSIXFailure.operation }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if !create && errno == ENOENT { return nil }
            throw POSIXFailure.operation
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), !create || fchmod(descriptor, 0o700) == 0 else {
            Darwin.close(descriptor)
            throw POSIXFailure.operation
        }
        return descriptor
    }

    private func managedID(_ name: String) -> UUID? {
        guard name.utf8.count == 41, name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(5))
        guard let id = UUID(uuidString: stem), id.uuidString.caseInsensitiveCompare(stem) == .orderedSame else { return nil }
        return id
    }

    private func scan(_ descriptor: Int32, report: inout AIUsageMaintenanceReport) throws -> [Entry] {
        report.ignoredEntryCount = 0
        // dup会共享目录偏移；每次用openat获得独立枚举游标。
        let cursor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cursor >= 0 else { throw POSIXFailure.operation }
        guard let stream = fdopendir(cursor) else { Darwin.close(cursor); throw POSIXFailure.operation }
        defer { closedir(stream) }
        var entries: [Entry] = []
        var seen: Set<UUID> = []
        errno = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                if let id = managedID(name) {
                    guard seen.insert(id).inserted else {
                        report.add(.duplicateRecordID(id), id: id)
                        throw POSIXFailure.operation
                    }
                    if let entry = inspect(descriptor, name: name, id: id) { entries.append(entry) }
                    else if errno != ENOENT {
                        report.add(.readFailed(id), id: id)
                        throw POSIXFailure.operation
                    }
                } else { report.ignoredEntryCount += 1 }
            }
            errno = 0
        }
        guard errno == 0 else { throw POSIXFailure.operation }
        return entries
    }

    private func inspect(_ descriptor: Int32, name: String, id: UUID, readHeader: Bool = true) -> Entry? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let regular = info.st_mode & S_IFMT == S_IFREG
        var entry = Entry(name: name, id: id, size: UInt64(max(0, info.st_size)), device: info.st_dev,
                          inode: info.st_ino, isRegular: regular, modified: info.st_mtimespec, changed: info.st_ctimespec, kind: regular ? .valid : .unsafe)
        guard regular else { return entry }
        guard info.st_size <= policy.maximumRecordBytes else { entry.kind = .oversized; return entry }
        if !readHeader { return entry }
        do {
            let data = try readRecord(descriptor, entry: entry)
            if let header = decodeHeader(data, id: id) { entry.recordedAt = header.recordedAt }
            else { entry.kind = .corrupt }
        } catch let error as RecordFailure { entry.kind = error == .oversized ? .oversized : .unreadable }
        catch { entry.kind = .unreadable }
        return entry
    }

    private func matches(_ info: stat, _ entry: Entry) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_dev == entry.device && info.st_ino == entry.inode &&
        UInt64(max(0, info.st_size)) == entry.size &&
        info.st_mtimespec.tv_sec == entry.modified.tv_sec && info.st_mtimespec.tv_nsec == entry.modified.tv_nsec &&
        info.st_ctimespec.tv_sec == entry.changed.tv_sec && info.st_ctimespec.tv_nsec == entry.changed.tv_nsec
    }

    private func readRecord(_ directoryFD: Int32, entry: Entry, maximumBytes: Int? = nil, observeRead: ((Int) -> Void)? = nil) throws -> Data {
        let limit = min(policy.maximumRecordBytes, maximumBytes ?? policy.maximumRecordBytes)
        let descriptor = openat(directoryFD, entry.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordFailure.read }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, matches(info, entry) else { throw RecordFailure.changed }
        guard info.st_size <= limit else { throw RecordFailure.oversized }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if result.count == limit { break }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, min($0.count, limit - result.count)) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw RecordFailure.read }
            observeRead?(count)
            guard count <= limit - result.count else { throw RecordFailure.oversized }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(descriptor, &info) == 0, matches(info, entry), info.st_size <= limit else { throw RecordFailure.changed }
        return result
    }

    private func expire(_ descriptor: Int32, entries: inout [Entry], now: Date,
                        report: inout AIUsageMaintenanceReport) async {
        let cutoff = now.addingTimeInterval(-policy.retentionInterval)
        reconcilePendingClear(entries)
        let candidates = entries.filter { entry in
            entry.kind == .valid && entry.recordedAt! <= cutoff || pendingClearEntries[entry.id] != nil
        }
        await deleteCandidates(descriptor, candidates: candidates, entries: &entries, report: &report)
    }

    private func makeRoom(_ descriptor: Int32, entries: inout [Entry], reservation: Reservation?,
                          report: inout AIUsageMaintenanceReport) async -> Bool {
        func projected(_ values: [Entry]) -> (Int, UInt64) {
            let included = values.filter { $0.name != reservation?.name }
            return (included.count + (reservation == nil ? 0 : 1),
                    included.reduce(reservation?.size ?? 0) { saturatedAdd($0, $1.size) })
        }
        func fits(_ values: [Entry]) -> Bool {
            let (count, bytes) = projected(values)
            return count <= policy.maximumCount && bytes <= policy.maximumTotalBytes
        }
        if fits(entries) { return true }
        // 无法自动删除的记录本身超额时，不白白清空所有正常、尚未过期的用量。
        guard fits(entries.filter { $0.kind != .valid }) else {
            report.add(.capacityExceeded)
            return false
        }
        var attempted = report.deferredIDs.union(report.failedIDs)
        while !fits(entries) {
            let fixed = entries.filter { $0.kind != .valid || attempted.contains($0.id) }
            guard fits(fixed) else { report.add(.capacityExceeded); return false }
            let candidates = entries.filter { $0.kind == .valid && $0.name != reservation?.name && !attempted.contains($0.id) }.sorted {
                $0.recordedAt == $1.recordedAt ? $0.name < $1.name : $0.recordedAt! < $1.recordedAt!
            }
            var projected = entries, selected: [Entry] = []
            for entry in candidates {
                if fits(projected) { break }
                selected.append(entry); projected.removeAll { $0.name == entry.name }
            }
            guard !selected.isEmpty else { report.add(.capacityExceeded); return false }
            attempted.formUnion(selected.map(\.id))
            let approved = await approveCandidates(selected, report: &report)
            do { entries = try scan(descriptor, report: &report) }
            catch { report.add(.enumerationFailed); return false }
            // live／失败候选本身已使预算不可能满足时，不继续删除其他正常记录。
            let blocked = attempted.subtracting(approved)
            guard fits(entries.filter { $0.kind != .valid || blocked.contains($0.id) }) else {
                report.add(.capacityExceeded); return false
            }
            for entry in selected where approved.contains(entry.id) {
                delete(descriptor, entry: entry, entries: &entries, report: &report)
            }
        }
        return true
    }

    private func approveCandidates(_ candidates: [Entry], report: inout AIUsageMaintenanceReport) async -> Set<UUID> {
        let ids = Set(candidates.map(\.id))
        guard !ids.isEmpty else { return [] }
        beginRetention()
        do {
            let prepared = try await prepareBudgets(ids, all: false, report: &report)
            let unresolved = ids.subtracting(prepared.approvedIDs).subtracting(prepared.deferredIDs)
            for id in unresolved { report.add(.budgetRedactionFailed(id), id: id) }
            return prepared.approvedIDs.intersection(ids)
        } catch {
            for id in ids { report.add(.budgetRedactionFailed(id), id: id) }
            return []
        }
    }

    private func prepareBudgets(_ ids: Set<UUID>, all: Bool, report: inout AIUsageMaintenanceReport) async throws -> InvocationUsageRemoval {
        let tickets = Array(pendingBudgetTickets.values)
        let prepared = try await prepareRemoval(ids, all, tickets)
        for ticket in tickets { pendingBudgetTickets[ticket.invocationID] = nil }
        for ticket in prepared.deferredBudgets { pendingBudgetTickets[ticket.invocationID] = ticket }
        report.budgetRedactedIDs.formUnion(prepared.budgetRedactedIDs)
        let resolved = prepared.approvedIDs.union(prepared.budgetRedactedIDs)
            .union(tickets.map(\.invocationID)).subtracting(prepared.deferredIDs)
        report.deferredIDs.subtract(resolved)
        report.deferredIDs.formUnion(prepared.deferredIDs)
        return prepared
    }

    private func deleteCandidates(_ descriptor: Int32, candidates: [Entry], entries: inout [Entry],
                                  report: inout AIUsageMaintenanceReport) async {
        let approved = await approveCandidates(candidates, report: &report)
        // actor等待期间外部替换仍可能发生；删除前复核原候选，容量按真实盘点重算。
        do { entries = try scan(descriptor, report: &report) }
        catch { report.add(.enumerationFailed); return }
        for entry in candidates where approved.contains(entry.id) {
            delete(descriptor, entry: entry, entries: &entries, report: &report)
        }
    }

    private func sameEntry(_ first: Entry, _ second: Entry) -> Bool {
        first.device == second.device && first.inode == second.inode && first.size == second.size &&
        first.modified.tv_sec == second.modified.tv_sec && first.modified.tv_nsec == second.modified.tv_nsec &&
        first.changed.tv_sec == second.changed.tv_sec && first.changed.tv_nsec == second.changed.tv_nsec
    }
    private func reconcilePendingClear(_ entries: [Entry]) {
        let current = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        pendingClearEntries = pendingClearEntries.filter { id, old in current[id].map { sameEntry(old, $0) } == true }
    }

    private func delete(_ descriptor: Int32, entry: Entry, entries: inout [Entry],
                        report: inout AIUsageMaintenanceReport) {
        var current = stat()
        guard fstatat(descriptor, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                entries.removeAll { $0.name == entry.name }
                do { try recordPendingUnlink(descriptor, entry: entry) }
                catch { report.uncertainRemovedIDs.insert(entry.id); report.add(.deletionUncertain(entry.id), id: entry.id) }
                return
            }
            report.add(.deletionFailed(entry.id), id: entry.id)
            return
        }
        guard entry.isRegular && matches(current, entry) else {
            report.add(.changedCandidate(entry.id), id: entry.id)
            return
        }
        do {
            let identity = try validatePendingDirectory(descriptor)
            try removeEntry(descriptor, entry.name)
            pendingDirectory = identity; pendingUnlinks[entry.id] = entry
            entries.removeAll { $0.name == entry.name }
        } catch { report.add(.deletionFailed(entry.id), id: entry.id) }
    }

    private func validatePendingDirectory(_ descriptor: Int32) throws -> (dev_t, ino_t) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXFailure.operation }
        if let pendingDirectory {
            guard pendingDirectory.0 == info.st_dev && pendingDirectory.1 == info.st_ino else { throw POSIXFailure.operation }
        }
        return (info.st_dev, info.st_ino)
    }
    private func recordPendingUnlink(_ descriptor: Int32, entry: Entry) throws {
        pendingDirectory = try validatePendingDirectory(descriptor); pendingUnlinks[entry.id] = entry
    }

    private func synchronizeRemovals(_ descriptor: Int32, report: inout AIUsageMaintenanceReport) {
        guard !pendingUnlinks.isEmpty else { return }
        beginRetention()
        do {
            var directoryInfo = stat()
            guard fstat(descriptor, &directoryInfo) == 0, let pendingDirectory,
                  pendingDirectory.0 == directoryInfo.st_dev && pendingDirectory.1 == directoryInfo.st_ino else { throw POSIXFailure.operation }
            try syncDirectory(descriptor)
            var unconfirmed: [UUID: Entry] = [:]
            for entry in pendingUnlinks.values {
                var current = stat()
                if fstatat(descriptor, entry.name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT {
                        report.removedIDs.insert(entry.id); report.removedCount += 1
                        report.removedBytes = saturatedAdd(report.removedBytes, entry.size)
                    } else {
                        unconfirmed[entry.id] = entry; report.uncertainRemovedIDs.insert(entry.id)
                        report.add(.deletionUncertain(entry.id), id: entry.id)
                    }
                } else if matches(current, entry) {
                    unconfirmed[entry.id] = entry; report.add(.deletionFailed(entry.id), id: entry.id)
                }
            }
            pendingUnlinks = unconfirmed
            if unconfirmed.isEmpty { self.pendingDirectory = nil }
        } catch {
            for id in pendingUnlinks.keys {
                report.uncertainRemovedIDs.insert(id); report.add(.deletionUncertain(id), id: id)
            }
        }
    }

    private func finalize(_ entries: [Entry], report: inout AIUsageMaintenanceReport) {
        report.remainingIDs = Set(entries.map(\.id))
        report.removedIDs.subtract(report.remainingIDs)
        report.remainingCount = entries.count
        report.remainingBytes = entries.reduce(0) { saturatedAdd($0, $1.size) }
        for entry in entries {
            if let problem = entry.problem { report.add(problem, id: entry.id) }
        }
        if (entries.count > policy.maximumCount || report.remainingBytes > policy.maximumTotalBytes),
           !report.problems.contains(.capacityExceeded) { report.add(.capacityExceeded) }
    }

    private func saturatedAdd(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let sum = first.addingReportingOverflow(second)
        return sum.overflow ? .max : sum.partialValue
    }

    private func writeRecord(_ directoryFD: Int32, name: String, data: Data) throws {
        let temporary = ".usage-" + UUID().uuidString + ".tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXFailure.operation }
        defer { Darwin.close(descriptor); _ = unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw POSIXFailure.operation }
                guard count > 0 else { throw POSIXFailure.operation }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXFailure.operation }
        var target = stat()
        if fstatat(directoryFD, name, &target, AT_SYMLINK_NOFOLLOW) == 0 {
            guard target.st_mode & S_IFMT == S_IFREG else { throw POSIXFailure.operation }
        } else if errno != ENOENT { throw POSIXFailure.operation }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0, fsync(directoryFD) == 0 else {
            throw POSIXFailure.operation
        }
    }
}
