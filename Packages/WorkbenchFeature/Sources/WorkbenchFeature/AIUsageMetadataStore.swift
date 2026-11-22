import Foundation
import Darwin

/// 只管理用量元数据；调用方不得传入提示词、输出、密钥或窗口引用。
struct AIUsageRetentionPolicy: Sendable {
    var retentionInterval: TimeInterval = 90 * 86_400
    var maximumCount: Int = 5_000
    var maximumTotalBytes: UInt64 = 16 * 1_024 * 1_024
    var maximumRecordBytes: Int = 64 * 1_024
}

enum AIUsageMaintenanceTrigger: Sendable { case startup, daily, afterSave, manual, clear }

enum AIUsageStorageProblem: Sendable, Equatable {
    case directoryUnavailable, enumerationFailed, capacityExceeded
    case malformedRecord(UUID), oversizedRecord(UUID), unsafeEntry(UUID)
    case readFailed(UUID), deletionFailed(UUID), writeFailed(UUID), expiredIncomingRecord(UUID)
}

struct AIUsageMaintenanceReport: Sendable {
    let trigger: AIUsageMaintenanceTrigger
    var removedIDs: Set<UUID> = []
    var remainingIDs: Set<UUID> = []
    var failedIDs: Set<UUID> = []
    var removedCount = 0
    var removedBytes: UInt64 = 0
    var remainingCount = 0
    var remainingBytes: UInt64 = 0
    var ignoredEntryCount = 0
    var didReadDirectory = false
    /// 最多保留64个问题详情，总问题数不截断。
    var problems: [AIUsageStorageProblem] = []
    var problemCount = 0
    var isComplete: Bool { didReadDirectory && problemCount == 0 }

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
}

/// 文件I/O在actor上串行执行，不阻塞MainActor，也不持有Store或窗口。
actor AIUsageMetadataStore {
    typealias ReportHandler = @Sendable (AIUsageMaintenanceReport) -> Void
    typealias RemoveEntry = @Sendable (Int32, String) throws -> Void

    private let directory: URL
    private let policy: AIUsageRetentionPolicy
    private let clock: @Sendable () -> Date
    private let dailyInterval: Duration
    private var reportHandler: ReportHandler
    private let removeEntry: RemoveEntry
    private var dailyTask: Task<Void, Never>?
    private var scheduleGeneration: UInt64 = 0

    init(directory: URL, policy: AIUsageRetentionPolicy = .init(),
         clock: @escaping @Sendable () -> Date = { Date() },
         dailyInterval: Duration = .seconds(86_400),
         reportHandler: @escaping ReportHandler = { _ in },
         removeEntry: @escaping RemoveEntry = { descriptor, name in
             guard unlinkat(descriptor, name, 0) == 0 else { throw POSIXFailure.operation }
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
    }

    deinit { dailyTask?.cancel() }

    func setReportHandler(_ handler: @escaping ReportHandler) { reportHandler = handler }

    @discardableResult func start() -> AIUsageMaintenanceReport {
        let report = performMaintenance(trigger: .startup)
        reportHandler(report)
        if dailyTask == nil {
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

    @discardableResult func maintain() -> AIUsageMaintenanceReport {
        let report = performMaintenance(trigger: .manual)
        reportHandler(report)
        return report
    }

    @discardableResult func clear() -> AIUsageMaintenanceReport {
        let report = performMaintenance(trigger: .clear)
        reportHandler(report)
        return report
    }

    func read(id: UUID) -> AIUsageMetadataReadResult {
        do {
            guard let descriptor = try openDirectory(create: false) else { return .init(data: nil, problem: nil) }
            defer { close(descriptor) }
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

    /// 保存前先验证，按包含新记录的投影预算逐出旧记录，容量无法满足时拒绝写入。
    func save(id: UUID, data: Data) -> AIUsageMetadataWriteResult {
        var report = AIUsageMaintenanceReport(trigger: .afterSave)
        guard data.count <= policy.maximumRecordBytes else {
            report.add(.oversizedRecord(id), id: id)
            return completeWrite(stored: false, report: report)
        }
        guard let header = decodeHeader(data, id: id) else {
            report.add(.malformedRecord(id), id: id)
            return completeWrite(stored: false, report: report)
        }
        let now = clock()
        guard header.recordedAt > now.addingTimeInterval(-policy.retentionInterval) else {
            report.add(.expiredIncomingRecord(id), id: id)
            return completeWrite(stored: false, report: report)
        }
        do {
            guard let descriptor = try openDirectory(create: true) else { throw POSIXFailure.operation }
            defer { close(descriptor) }
            var entries = try scan(descriptor, report: &report)
            report.didReadDirectory = true
            let name = id.uuidString + ".json"
            if let target = entries.first(where: { $0.name == name }), !target.isRegular {
                report.add(.unsafeEntry(id), id: id)
                finalize(entries, report: &report)
                return completeWrite(stored: false, report: report)
            }
            expire(descriptor, entries: &entries, now: now, report: &report)
            let reserved = Reservation(name: name, size: UInt64(data.count))
            guard makeRoom(descriptor, entries: &entries, reservation: reserved, report: &report) else {
                finalize(entries, report: &report)
                return completeWrite(stored: false, report: report)
            }
            var stored = false
            do { try writeRecord(descriptor, name: name, data: data); stored = true }
            catch { report.add(.writeFailed(id), id: id) }
            // 写入失败也可能发生在rename后的fsync：重新盘点，不能虚假声称文件不存在。
            report.ignoredEntryCount = 0
            entries = try scan(descriptor, report: &report)
            finalize(entries, report: &report)
            return completeWrite(stored: stored, report: report)
        } catch {
            report.add(report.didReadDirectory ? .enumerationFailed : .directoryUnavailable)
            return completeWrite(stored: false, report: report)
        }
    }

    private func completeWrite(stored: Bool, report: AIUsageMaintenanceReport) -> AIUsageMetadataWriteResult {
        reportHandler(report)
        return .init(stored: stored, report: report)
    }

    private func performDailyMaintenance(generation: UInt64) {
        guard generation == scheduleGeneration, dailyTask != nil else { return }
        reportHandler(performMaintenance(trigger: .daily))
    }

    private func performMaintenance(trigger: AIUsageMaintenanceTrigger) -> AIUsageMaintenanceReport {
        var report = AIUsageMaintenanceReport(trigger: trigger)
        do {
            guard let descriptor = try openDirectory(create: trigger != .clear) else {
                report.didReadDirectory = true
                return report
            }
            defer { close(descriptor) }
            var entries = try scan(descriptor, report: &report)
            report.didReadDirectory = true
            if trigger == .clear {
                // 显式清除可删除损坏/超限的普通文件，符号链接和其他文件类型仍保留并报告。
                for entry in entries where entry.isRegular {
                    delete(descriptor, entry: entry, entries: &entries, report: &report)
                }
            } else {
                expire(descriptor, entries: &entries, now: clock(), report: &report)
                _ = makeRoom(descriptor, entries: &entries, reservation: nil, report: &report)
            }
            finalize(entries, report: &report)
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
            close(descriptor)
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
        // dup会共享目录偏移；每次用openat获得独立枚举游标。
        let cursor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cursor >= 0 else { throw POSIXFailure.operation }
        guard let stream = fdopendir(cursor) else { close(cursor); throw POSIXFailure.operation }
        defer { closedir(stream) }
        var entries: [Entry] = []
        errno = 0
        while let item = readdir(stream) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                if let id = managedID(name) {
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

    private func inspect(_ descriptor: Int32, name: String, id: UUID) -> Entry? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let regular = info.st_mode & S_IFMT == S_IFREG
        var entry = Entry(name: name, id: id, size: UInt64(max(0, info.st_size)), device: info.st_dev,
                          inode: info.st_ino, isRegular: regular, kind: regular ? .valid : .unsafe)
        guard regular else { return entry }
        guard info.st_size <= policy.maximumRecordBytes else { entry.kind = .oversized; return entry }
        do {
            let data = try readRecord(descriptor, entry: entry)
            if let header = decodeHeader(data, id: id) { entry.recordedAt = header.recordedAt }
            else { entry.kind = .corrupt }
        } catch let error as RecordFailure { entry.kind = error == .oversized ? .oversized : .unreadable }
        catch { entry.kind = .unreadable }
        return entry
    }

    private func matches(_ info: stat, _ entry: Entry) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_dev == entry.device && info.st_ino == entry.inode
    }

    private func readRecord(_ directoryFD: Int32, entry: Entry) throws -> Data {
        let descriptor = openat(directoryFD, entry.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecordFailure.read }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, matches(info, entry) else { throw RecordFailure.changed }
        guard info.st_size <= policy.maximumRecordBytes else { throw RecordFailure.oversized }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw RecordFailure.read }
            guard count <= policy.maximumRecordBytes - result.count else { throw RecordFailure.oversized }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func expire(_ descriptor: Int32, entries: inout [Entry], now: Date,
                        report: inout AIUsageMaintenanceReport) {
        let cutoff = now.addingTimeInterval(-policy.retentionInterval)
        for entry in entries where entry.kind == .valid && entry.recordedAt! <= cutoff {
            delete(descriptor, entry: entry, entries: &entries, report: &report)
        }
    }

    private func makeRoom(_ descriptor: Int32, entries: inout [Entry], reservation: Reservation?,
                          report: inout AIUsageMaintenanceReport) -> Bool {
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
        let candidates = entries.filter { $0.kind == .valid && $0.name != reservation?.name }.sorted {
            $0.recordedAt == $1.recordedAt ? $0.name < $1.name : $0.recordedAt! < $1.recordedAt!
        }
        for entry in candidates {
            if fits(entries) { return true }
            delete(descriptor, entry: entry, entries: &entries, report: &report)
        }
        guard fits(entries) else { report.add(.capacityExceeded); return false }
        return true
    }

    private func delete(_ descriptor: Int32, entry: Entry, entries: inout [Entry],
                        report: inout AIUsageMaintenanceReport) {
        var current = stat()
        guard fstatat(descriptor, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { entries.removeAll { $0.name == entry.name }; return }
            report.add(.deletionFailed(entry.id), id: entry.id)
            return
        }
        guard entry.isRegular && matches(current, entry) else {
            report.add(.deletionFailed(entry.id), id: entry.id)
            return
        }
        do {
            try removeEntry(descriptor, entry.name)
            entries.removeAll { $0.name == entry.name }
            report.removedIDs.insert(entry.id)
            report.removedCount += 1
            report.removedBytes = saturatedAdd(report.removedBytes, entry.size)
        } catch { report.add(.deletionFailed(entry.id), id: entry.id) }
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
        defer { close(descriptor); _ = unlinkat(directoryFD, temporary, 0) }
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
