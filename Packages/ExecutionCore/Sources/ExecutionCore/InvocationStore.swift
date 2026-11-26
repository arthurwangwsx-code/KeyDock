import Darwin
import Foundation

public struct InvocationReceipt: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var state: ExecutionState
    public let startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var message: String
    public var commandID: String?
    public var commandVersion: Int?
    public var configurationFingerprint: String?
    public var caller: String?
    public var desktopWorkspace: DesktopWorkspaceReceiptContext?
    public var desktopWorkspaceRun: DesktopWorkspaceRunContext?
    public var desktopWorkspaceResult: DesktopWorkspaceRunResult?
    public var runAttempt: RunAttemptMetadata?
    public var runTokenBudget: RunTokenBudgetSnapshot?

    public init(id: UUID, name: String, state: ExecutionState, startedAt: Date = Date(), finishedAt: Date? = nil, exitCode: Int32? = nil, message: String = "", commandID: String? = nil, commandVersion: Int? = nil, configurationFingerprint: String? = nil, caller: String? = nil, desktopWorkspace: DesktopWorkspaceReceiptContext? = nil, desktopWorkspaceRun: DesktopWorkspaceRunContext? = nil, desktopWorkspaceResult: DesktopWorkspaceRunResult? = nil, runAttempt: RunAttemptMetadata? = nil, runTokenBudget: RunTokenBudgetSnapshot? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.message = message
        self.commandID = commandID; self.commandVersion = commandVersion
        self.configurationFingerprint = configurationFingerprint; self.caller = caller
        self.desktopWorkspace = desktopWorkspace
        self.desktopWorkspaceRun = desktopWorkspaceRun
        self.desktopWorkspaceResult = desktopWorkspaceResult
        self.runAttempt = runAttempt
        self.runTokenBudget = runTokenBudget
    }
}

public enum InvocationStoreError: Error, Equatable, Sendable {
    case invalidDirectory, unsupportedVersion, duplicateInvocation, missingInvocation, nonterminalResult, io(Int32)
    case invalidPolicy, invalidClock, invalidMetadata, invalidFile, loadLimitExceeded, capacityExceeded
    case durabilityUncertain(Int32)
    case recoveryUnavailable, staleRecovery, foreignRecovery, activeRecovery, recoveryPersistenceUncertain, revisionExhausted
}

/// 只记录最小元数据；不保存正文、不重放任务。维护与显式清除只处理未保护的终态。
public actor InvocationStore {
    private struct Envelope: Codable {
        let version: Int
        let receipts: [InvocationReceipt]
        enum CodingKeys: String, CodingKey { case version, receipts }
        enum BudgetKey: String, CodingKey { case runTokenBudget }
        init(version: Int, receipts: [InvocationReceipt]) { self.version = version; self.receipts = receipts }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            guard (1...3).contains(version) else { throw InvocationStoreError.unsupportedVersion }
            var rows = try c.nestedUnkeyedContainer(forKey: .receipts), values: [InvocationReceipt] = []
            while !rows.isAtEnd {
                let row = try rows.superDecoder(), keys = try row.container(keyedBy: BudgetKey.self)
                if keys.contains(.runTokenBudget) {
                    guard version == 3, try !keys.decodeNil(forKey: .runTokenBudget) else { throw InvocationStoreError.invalidMetadata }
                }
                values.append(try InvocationReceipt(from: row))
            }
            receipts = values
        }
    }
    private struct WriteFailure: Error { let code: Int32; let renamed: Bool }
    // 固定目录对象；后续路径被rename或换成符号链接也不能改变读写目标。
    private let directoryFD: Int32
    private static let fileName = "invocations.json"
    private let retention: InvocationRetentionPolicy
    private let clock: @Sendable () -> Date
    private var receipts: [UUID: InvocationReceipt]
    private var recoveredProtection: Set<UUID>
    private var liveProtectedIDs: Set<UUID> = []
    private var liveParentIDs: Set<UUID> = []
    private var pendingPersistence = false
    private let runStoreIdentity = UUID()
    private var usageBirths: [UUID: UUID] = [:]
    private var liveRecoverySources: [UUID: UUID] = [:]
    private let persistenceFault: @Sendable (InvocationPersistencePoint) -> Int32?
    // finish仅增加固定元数据；begin为每个intent预留结果空间，避免正常完成被自身预算卡住。
    private static let completionReserveBytes = 4_096

    public init(directory: URL, retention: InvocationRetentionPolicy = .init(),
                clock: @escaping @Sendable () -> Date = { Date() },
                persistenceFault: @escaping @Sendable (InvocationPersistencePoint) -> Int32? = { _ in nil }) throws {
        guard retention.maxFinishedAge.isFinite, retention.maxFinishedAge >= 0,
              retention.maxFinishedCount >= 0, retention.maxFileBytes >= 128,
              retention.maxLoadBytes >= retention.maxFileBytes,
              retention.maxLoadBytes <= 64 * 1_048_576 else { throw InvocationStoreError.invalidPolicy }
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw InvocationStoreError.invalidClock }
        guard directory.isFileURL else { throw InvocationStoreError.invalidDirectory }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pinnedDirectory = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard pinnedDirectory >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw InvocationStoreError.invalidDirectory }
            throw InvocationStoreError.io(errno)
        }
        // 所有可失败的初始化完成后才转交给actor；中途抛错只由defer关闭一次。
        var transferredOwnership = false
        defer { if !transferredOwnership { Darwin.close(pinnedDirectory) } }
        var directoryInfo = stat()
        guard fstat(pinnedDirectory, &directoryInfo) == 0 else { throw InvocationStoreError.io(errno) }
        guard directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw InvocationStoreError.invalidDirectory }
        guard fchmod(pinnedDirectory, mode_t(0o700)) == 0 else { throw InvocationStoreError.io(errno) }
        var values: [UUID: InvocationReceipt] = [:], recovered: Set<UUID> = []
        if let data = try Self.readBounded(directoryFD: pinnedDirectory, maximum: retention.maxLoadBytes) {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            for var receipt in envelope.receipts {
                guard values[receipt.id] == nil else { throw InvocationStoreError.duplicateInvocation }
                guard envelope.version >= 2 || receipt.runAttempt == nil else { throw InvocationStoreError.invalidMetadata }
                guard receipt.startedAt.timeIntervalSinceReferenceDate.isFinite,
                      receipt.finishedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw InvocationStoreError.invalidMetadata }
                try Self.validateWorkspaceContext(receipt.desktopWorkspace, commandID: receipt.commandID, id: receipt.id)
                guard receipt.desktopWorkspace == nil || receipt.desktopWorkspaceRun == nil else { throw InvocationStoreError.invalidMetadata }
                try receipt.desktopWorkspaceResult?.validate(manifest: receipt.desktopWorkspaceRun)
                if let result = receipt.desktopWorkspaceResult { guard receipt.state.isTerminal, result.state == receipt.state else { throw InvocationStoreError.invalidMetadata } }
                if !receipt.state.isTerminal {
                    recovered.insert(receipt.id)
                    receipt.state = .interrupted; receipt.finishedAt = now; receipt.exitCode = nil
                    receipt.message = receipt.message == "terminal.handoffIntent" ? "terminal.handoffUnknown" : "process.interrupted.unknown"
                    if let budget = receipt.runTokenBudget {
                        receipt.runTokenBudget = .init(maximumTokens: budget.maximumTokens, knownTokens: budget.knownTokens, completedTurns: budget.completedTurns, status: .usageUnavailable)
                    }
                }
                values[receipt.id] = receipt
            }
        }
        for value in values.values { try Self.validateWorkspaceParent(value.desktopWorkspace, in: values) }
        try RunAttemptValidation.validate(values)
        // 父恢复前不能裁掉已确认的child；孤立进行中child也保护其已知父及兄弟事实。
        let recoveredFamilies = recovered.union(recovered.compactMap { Self.parentID(values[$0]?.commandID) })
        recovered.formUnion(values.values.filter { value in
            recoveredFamilies.contains(value.id) || Self.parentID(value.commandID).map(recoveredFamilies.contains) == true
        }.map(\.id))
        // 冷启动只保护未确认尝试的直接来源，不能把整条逻辑历史永久豁免保留预算。
        recovered.formUnion(recovered.compactMap { values[$0]?.runAttempt?.recoveryOf })
        let maintained = try Self.pruned(values, retention: retention, now: now, protecting: recovered)
        self.retention = retention; self.clock = clock; self.persistenceFault = persistenceFault
        self.receipts = maintained; self.recoveredProtection = recovered
        self.usageBirths = Dictionary(uniqueKeysWithValues: maintained.keys.map { ($0, UUID()) })
        let data = try Self.encoded(maintained)
        if Self.byteBudgetFits(maintained, encodedBytes: data.count, retention: retention) {
            do { try Self.persist(data, directoryFD: pinnedDirectory, fault: persistenceFault) }
            catch let failure as WriteFailure { throw Self.publicError(failure) }
        } else {
            // 旧intent证据优先；原文件保持不动，先让宿主展示unknown，再ack与maintain。
            pendingPersistence = true
        }
        self.directoryFD = pinnedDirectory
        transferredOwnership = true
    }

    deinit { Darwin.close(directoryFD) }

    @discardableResult public func begin(id: UUID, name: String, commandID: String? = nil, commandVersion: Int? = nil,
                      configurationFingerprint: String? = nil, caller: String? = nil, initialMessage: String = "",
                      desktopWorkspace: DesktopWorkspaceReceiptContext? = nil, desktopWorkspaceRun: DesktopWorkspaceRunContext? = nil,
                      runDefinition: RunDefinitionReference? = nil, runTokenBudget: RunTokenBudgetSnapshot? = nil,
                      recovering check: RunRecoveryCheck? = nil) throws -> InvocationBeginReceipt {
        guard receipts[id] == nil else { throw InvocationStoreError.duplicateInvocation }
        if let budget = runTokenBudget {
            guard budget.isValid, budget.status == .awaitingUsage, budget.knownTokens == 0, budget.completedTurns == 0 else { throw InvocationStoreError.invalidMetadata }
        }
        // 缺失但仍被引用的历史ID不能重用，否则会重绑旧祖先，甚至把合法历史写成坏图。
        guard !receipts.values.contains(where: { $0.runAttempt?.logicalRunID == id || $0.runAttempt?.recoveryOf == id }) else { throw InvocationStoreError.duplicateInvocation }
        guard (commandID?.utf8.count ?? 0) <= 512, (configurationFingerprint?.utf8.count ?? 0) <= 256,
              (caller?.utf8.count ?? 0) <= 128, initialMessage.utf8.count <= 512,
              commandVersion.map({ $0 > 0 }) != false else { throw InvocationStoreError.invalidMetadata }
        try Self.validateWorkspaceContext(desktopWorkspace, commandID: commandID, id: id)
        guard desktopWorkspace == nil || desktopWorkspaceRun == nil else { throw InvocationStoreError.invalidMetadata }
        try Self.validateWorkspaceParent(desktopWorkspace, in: receipts, requireActive: true)
        let parent = Self.parentID(commandID)
        guard parent == nil || liveParentIDs.contains(parent!) || liveParentIDs.count < 64 else { throw InvocationStoreError.capacityExceeded }
        let now = try currentTime()
        var next = receipts
        var runAttempt: RunAttemptMetadata?
        var recoverySource: UUID?
        if let check {
            let source = try checkedRecovery(check)
            guard let definition = runDefinition, definition.isValid, var original = source.runAttempt,
                  definition.kind == original.definition.kind, definition.definitionID == original.definition.definitionID,
                  original.logicalRunID != id else { throw InvocationStoreError.invalidMetadata }
            guard original.revision < UInt64.max else { throw InvocationStoreError.revisionExhausted }
            runAttempt = .init(logicalRunID: original.logicalRunID, recoveryOf: source.id, definition: definition)
            original.revision += 1
            next[source.id]?.runAttempt = original
            recoverySource = source.id
        } else if let definition = runDefinition {
            guard definition.isValid else { throw InvocationStoreError.invalidMetadata }
            runAttempt = .init(logicalRunID: id, definition: definition)
        }
        next[id] = .init(id: id, name: String(Self.boundedName(name).prefix(256)), state: .running,
            startedAt: now, message: initialMessage, commandID: commandID, commandVersion: commandVersion,
            configurationFingerprint: configurationFingerprint, caller: caller, desktopWorkspace: desktopWorkspace, desktopWorkspaceRun: desktopWorkspaceRun, runAttempt: runAttempt, runTokenBudget: runTokenBudget)
        if runAttempt != nil { try RunAttemptValidation.validate(next) }
        do {
            try commit(next); liveProtectedIDs.insert(id); if let parent { liveParentIDs.insert(parent) }
            if let recoverySource { liveRecoverySources[id] = recoverySource }
            let receipt = next[id]!
            return .init(receipt: receipt, runStamp: runAttempt.map { .init(invocationID: id, metadata: $0, storeIdentity: runStoreIdentity) })
        }
        catch {
            if receipts[id] != nil {
                liveProtectedIDs.insert(id); if let parent { liveParentIDs.insert(parent) }
                if let recoverySource { liveRecoverySources[id] = recoverySource }
                if let metadata = receipts[id]?.runAttempt, let cause = error as? InvocationStoreError {
                    throw InvocationBeginFailure(cause: cause, undispatchedStamp: .init(invocationID: id, metadata: metadata, storeIdentity: runStoreIdentity))
                }
            }
            throw error
        }
    }

    public func finish(id: UUID, result: ProcessResult, desktopWorkspaceResult: DesktopWorkspaceRunResult? = nil, runTokenBudget: RunTokenBudgetSnapshot? = nil, expectedRunStamp: RunAttemptStamp? = nil) throws {
        guard let receipt = receipts[id] else { throw InvocationStoreError.missingInvocation }
        guard receipt.runAttempt == nil || expectedRunStamp != nil else { throw InvocationStoreError.staleRecovery }
        if let expectedRunStamp {
            guard !pendingPersistence else { throw InvocationStoreError.recoveryPersistenceUncertain }
            guard expectedRunStamp.storeIdentity == runStoreIdentity else { throw InvocationStoreError.foreignRecovery }
            guard expectedRunStamp.invocationID == id, receipt.runAttempt?.revision == expectedRunStamp.revision,
                  receipt.runAttempt?.recordIdentity == expectedRunStamp.recordIdentity else { throw InvocationStoreError.staleRecovery }
        }
        try finishResult(id: id, result: result, desktopWorkspaceResult: desktopWorkspaceResult, runTokenBudget: runTokenBudget)
    }

    private func finishResult(id: UUID, result: ProcessResult, desktopWorkspaceResult: DesktopWorkspaceRunResult? = nil, runTokenBudget: RunTokenBudgetSnapshot? = nil) throws {
        guard var receipt = receipts[id] else { throw InvocationStoreError.missingInvocation }
        guard result.state.isTerminal else { throw InvocationStoreError.nonterminalResult }
        // 不覆盖取消/恢复后的终态；不确定的持久状态由显式维护重试确认。
        guard !receipt.state.isTerminal else { return }
        guard result.message.utf8.count <= 512 else { throw InvocationStoreError.invalidMetadata }
        if let budget = runTokenBudget {
            guard budget.isValid, let original = receipt.runTokenBudget, original.maximumTokens == budget.maximumTokens,
                  original.policyVersion == budget.policyVersion else { throw InvocationStoreError.invalidMetadata }
            receipt.runTokenBudget = budget
        }
        if let budget = receipt.runTokenBudget, budget.status == .awaitingUsage {
            receipt.runTokenBudget = .init(maximumTokens: budget.maximumTokens, knownTokens: budget.knownTokens, completedTurns: budget.completedTurns, status: .usageUnavailable)
        }
        try desktopWorkspaceResult?.validate(manifest: receipt.desktopWorkspaceRun)
        if let workspace = desktopWorkspaceResult { guard workspace.state == result.state else { throw InvocationStoreError.invalidMetadata } }
        receipt.desktopWorkspaceResult = desktopWorkspaceResult
        receipt.state = result.state; receipt.finishedAt = try currentTime()
        receipt.exitCode = result.exitCode; receipt.message = result.message
        var next = receipts; next[id] = receipt
        // begin/finish不裁剪；宿主消费完成、释放handle后才显式maintain。
        try commit(next)
    }

    public func list() -> [InvocationReceipt] {
        receipts.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func materialOwner(_ id: UUID) throws -> RunMaterialOwner? {
        guard !pendingPersistence else { throw InvocationStoreError.recoveryPersistenceUncertain }
        guard let metadata = receipts[id]?.runAttempt else { return nil }
        return .init(invocationID: id, recordIdentity: metadata.recordIdentity, kind: metadata.definition.kind)
    }
    public func materialOwners() throws -> [RunMaterialOwner] {
        guard !pendingPersistence else { throw InvocationStoreError.recoveryPersistenceUncertain }
        return receipts.values.compactMap { receipt in
            receipt.runAttempt.map { .init(invocationID: receipt.id, recordIdentity: $0.recordIdentity, kind: $0.definition.kind) }
        }
    }

    public func inspectRecovery(_ id: UUID) throws -> RunRecoveryCheck {
        guard !pendingPersistence else { throw InvocationStoreError.recoveryPersistenceUncertain }
        guard let receipt = receipts[id], receipt.runAttempt != nil else { throw InvocationStoreError.recoveryUnavailable }
        let check = RunRecoveryCheck(receipt: receipt, storeIdentity: runStoreIdentity)
        _ = try checkedRecovery(check)
        return check
    }

    private func checkedRecovery(_ check: RunRecoveryCheck) throws -> InvocationReceipt {
        guard check.storeIdentity == runStoreIdentity else { throw InvocationStoreError.foreignRecovery }
        guard !pendingPersistence else { throw InvocationStoreError.recoveryPersistenceUncertain }
        guard let current = receipts[check.receipt.id], let metadata = current.runAttempt,
              metadata == check.receipt.runAttempt else { throw InvocationStoreError.staleRecovery }
        guard current.state.isTerminal else { throw InvocationStoreError.activeRecovery }
        guard !receipts.values.contains(where: { $0.runAttempt?.logicalRunID == metadata.logicalRunID &&
            (!$0.state.isTerminal || liveProtectedIDs.contains($0.id)) }) else { throw InvocationStoreError.activeRecovery }
        guard metadata.revision < UInt64.max else { throw InvocationStoreError.revisionExhausted }
        return current
    }

    public func runStoreSnapshot() throws -> RunStoreSnapshot {
        guard !pendingPersistence else { throw InvocationStoreError.recoveryPersistenceUncertain }
        let values = list(), groups = Dictionary(grouping: values.filter { $0.runAttempt != nil }, by: { $0.runAttempt!.logicalRunID })
        let runs = groups.map { id, attempts in
            LogicalRunRecord(id: id, attempts: attempts,
                hasMissingAncestors: attempts.contains { $0.runAttempt?.recoveryOf.map { receipts[$0] == nil } ?? false },
                hasLiveAttempts: attempts.contains { !$0.state.isTerminal || liveProtectedIDs.contains($0.id) })
        }.sorted { left, right in
            let l = left.attempts.first?.startedAt ?? .distantPast, r = right.attempts.first?.startedAt ?? .distantPast
            return l == r ? left.id.uuidString < right.id.uuidString : l > r
        }
        return .init(logicalRuns: runs, legacyReceipts: values.filter { $0.runAttempt == nil })
    }

    /// 宿主已经消费首次恢复快照后调用；读取list本身不隐式解除保护。
    public func acknowledgeRecovery() { recoveredProtection.removeAll() }
    /// handle/reservation与结果消费已收口后，由宿主显式释放；不解除旧恢复证据的保护。
    public func releaseProtection(for id: UUID, expectedRunStamp: RunAttemptStamp? = nil) {
        guard receipts[id]?.runAttempt == nil || expectedRunStamp != nil else { return }
        if let expectedRunStamp, !matches(expectedRunStamp, id: id) { return }
        liveProtectedIDs.remove(id); liveRecoverySources[id] = nil
    }
    public func releaseParentProtection(for id:UUID) { liveParentIDs.remove(id) }
    /// begin可能已rename后才抛错；尚未派发时尽力结束intent，并始终解除本进程lease。
    public func abandonUndispatched(_ id:UUID, expectedRunStamp: RunAttemptStamp? = nil) {
        guard receipts[id]?.runAttempt == nil || expectedRunStamp != nil else { return }
        if let expectedRunStamp, !matches(expectedRunStamp, id: id) { return }
        // 已核对本worker出生身份；未派发的补偿写可收口rename后的不确定intent，不能作为派发成功。
        if receipts[id]?.state.isTerminal == false { try? finishResult(id:id,result:.init(state:.cancelled,message:"invocation.notDispatched")) }
        liveProtectedIDs.remove(id)
        liveRecoverySources[id] = nil
    }

    private func matches(_ stamp: RunAttemptStamp, id: UUID) -> Bool {
        stamp.storeIdentity == runStoreIdentity && stamp.invocationID == id &&
        receipts[id]?.runAttempt?.recordIdentity == stamp.recordIdentity && receipts[id]?.runAttempt?.revision == stamp.revision
    }

    public func maintain(protecting ids: Set<UUID> = [], protectingParents parents: Set<UUID> = []) -> InvocationCleanupReport {
        let protected = protectedIDs(ids.union(children(of: parents)))
        do {
            let now = try currentTime()
            let next = try Self.pruned(receipts, retention: retention, now: now, protecting: protected)
            return applyCleanup(next, protected: protected)
        } catch {
            return report(removed: [], failed: [], protected: protected, failure: cleanupFailure(error))
        }
    }

    /// onlyIDs固定本次UI候选，避免await间新完成任务被顺带清除；进行中intent永不删除。
    public func clearFinished(onlyIDs: Set<UUID>? = nil, excluding ids: Set<UUID> = [], protectingParents parents: Set<UUID> = []) -> InvocationCleanupReport {
        let protected = protectedIDs(ids.union(children(of: parents)))
        let candidates = onlyIDs ?? Set(receipts.keys)
        let removed = candidates.subtracting(protected).intersection(receipts.keys)
        var next = receipts
        for id in removed { next[id] = nil }
        return applyCleanup(next, protected: protected)
    }

    /// 清除已收口预算中的用量副本，保留冻结阈值；不修改在途meter或授予重新执行权限。
    public func clearRecordedRunTokenUsage() throws -> Set<UUID> {
        try prepareUsageRemoval(for: [], clearingAllRecorded: true).budgetRedactedIDs
    }

    /// ledger仅能消费已持久确认的候选；旧recovery来源不永久豁免用量清理。
    public func prepareUsageRemoval(for ids: Set<UUID>, clearingAllRecorded: Bool = false,
                                    retrying tickets: [InvocationUsageClearTicket] = []) throws -> InvocationUsageRemoval {
        // 只重写已知状态以核实durability，不重放调用或改变恢复身份。
        if pendingPersistence { try commit(receipts) }
        let retries = Set(tickets.filter { $0.storeIdentity == runStoreIdentity && usageBirths[$0.invocationID] == $0.birth }.map(\.invocationID))
        let selected = (clearingAllRecorded ? ids.union(receipts.keys) : ids).union(retries)
        var next = receipts, cleared: Set<UUID> = [], deferred: Set<UUID> = []
        var deferredBudgets: [InvocationUsageClearTicket] = []
        var changed = false
        for id in selected {
            guard !liveProtectedIDs.contains(id), receipts[id]?.state.isTerminal != false else {
                if ids.contains(id) { deferred.insert(id) }
                if let receipt = receipts[id], receipt.state.isTerminal, let budget = receipt.runTokenBudget,
                   budget.knownTokens != nil || budget.completedTurns != 0, let birth = usageBirths[id] {
                    deferred.insert(id)
                    deferredBudgets.append(.init(invocationID: id, storeIdentity: runStoreIdentity, birth: birth))
                }
                continue
            }
            guard let receipt = receipts[id] else { continue }
            guard let budget = receipt.runTokenBudget else { continue }
            let redacted = RunTokenBudgetSnapshot(maximumTokens: budget.maximumTokens, knownTokens: nil, completedTurns: 0, status: .usageUnavailable)
            changed = changed || redacted != budget
            next[id]?.runTokenBudget = redacted
            cleared.insert(id)
        }
        if changed { try commit(next) }
        return .init(approvedIDs: ids.subtracting(deferred), budgetRedactedIDs: cleared, deferredIDs: deferred, deferredBudgets: deferredBudgets)
    }

    /// 与清理共享actor事务，避免宿主快照之后新完成的子回执失去父运行保护。
    private static func parentID(_ commandID:String?) -> UUID? {
        guard let commandID else { return nil }
        for prefix in ["keydock.agent.","keydock.workflow-run.",DesktopWorkspaceReceiptContext.commandPrefix] where commandID.hasPrefix(prefix) {
            let suffix = String(commandID.dropFirst(prefix.count))
            if suffix.count == 36 { return UUID(uuidString:suffix) }
        }
        return nil
    }
    private static func validateWorkspaceContext(_ context: DesktopWorkspaceReceiptContext?, commandID: String?, id: UUID) throws {
        if let context {
            guard context.commandID == commandID, context.parentID != id else { throw InvocationStoreError.invalidMetadata }
        } else if commandID?.hasPrefix(DesktopWorkspaceReceiptContext.commandPrefix) == true { throw InvocationStoreError.invalidMetadata }
    }
    private static func validateWorkspaceParent(_ context: DesktopWorkspaceReceiptContext?, in values: [UUID: InvocationReceipt], requireActive: Bool = false) throws {
        guard let context else { return }
        guard let parent = values[context.parentID] else {
            if requireActive { throw InvocationStoreError.invalidMetadata }; return
        }
        guard let run = parent.desktopWorkspaceRun, run.entryIDs.indices.contains(context.entryIndex), run.entryIDs[context.entryIndex] == context.entryID,
              !requireActive || !parent.state.isTerminal else { throw InvocationStoreError.invalidMetadata }
    }
    private func children(of parents: Set<UUID>) -> Set<UUID> {
        Set(receipts.values.filter { value in Self.parentID(value.commandID).map(parents.contains) ?? false }.map(\.id))
    }
    private func currentTime() throws -> Date {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw InvocationStoreError.invalidClock }
        return now
    }
    private func protectedIDs(_ supplied: Set<UUID>) -> Set<UUID> {
        supplied.union(recoveredProtection).union(liveProtectedIDs).union(liveRecoverySources.values).union(children(of:liveParentIDs)).union(receipts.values.filter { !$0.state.isTerminal }.map(\.id))
    }
    private func commit(_ next: [UUID: InvocationReceipt]) throws {
        let data = try Self.encoded(next)
        guard Self.byteBudgetFits(next, encodedBytes: data.count, retention: retention) else { throw InvocationStoreError.capacityExceeded }
        do { try Self.persist(data, directoryFD: directoryFD, fault: persistenceFault); adopt(next); pendingPersistence = false }
        catch let failure as WriteFailure {
            if failure.renamed { adopt(next); pendingPersistence = true }
            throw Self.publicError(failure)
        }
    }
    private func adopt(_ next: [UUID: InvocationReceipt]) {
        usageBirths = Dictionary(uniqueKeysWithValues: next.keys.map { ($0, usageBirths[$0] ?? UUID()) })
        receipts = next
    }
    private func applyCleanup(_ next: [UUID: InvocationReceipt], protected: Set<UUID>) -> InvocationCleanupReport {
        let intended = Set(receipts.keys).subtracting(next.keys)
        guard !intended.isEmpty || pendingPersistence else { return report(removed: [], failed: [], protected: protected, failure: nil) }
        do {
            try commit(next)
            return report(removed: intended, failed: [], protected: protected, failure: nil)
        } catch {
            // rename后的目录同步失败不假报已持久删除；remaining仍反映actor当前逻辑状态。
            return report(removed: [], failed: intended, protected: protected, failure: cleanupFailure(error))
        }
    }
    private func report(removed: Set<UUID>, failed: Set<UUID>, protected: Set<UUID>, failure: InvocationCleanupFailure?) -> InvocationCleanupReport {
        let count = receipts.values.filter { $0.state.isTerminal }.count
        let fitsBytes = (try? Self.encoded(receipts).count).map { Self.byteBudgetFits(receipts, encodedBytes: $0, retention: retention) } ?? false
        return .init(removedIDs: removed, failedIDs: failed, remainingIDs: Set(receipts.keys),
            protectedIDs: protected.intersection(receipts.keys), limitsSatisfied: count <= retention.maxFinishedCount && fitsBytes, failure: failure)
    }
    private func cleanupFailure(_ error: any Error) -> InvocationCleanupFailure {
        switch error {
        case InvocationStoreError.capacityExceeded: .capacityExceeded
        case InvocationStoreError.invalidClock: .invalidClock
        case InvocationStoreError.durabilityUncertain(let code): .durabilityUncertain(code)
        case InvocationStoreError.io(let code): .io(code)
        default: .io(EIO)
        }
    }
    private static func publicError(_ failure: WriteFailure) -> InvocationStoreError {
        failure.renamed ? .durabilityUncertain(failure.code) : .io(failure.code)
    }
    private static func byteBudgetFits(_ values: [UUID: InvocationReceipt], encodedBytes: Int, retention: InvocationRetentionPolicy) -> Bool {
        let active = values.values.filter { !$0.state.isTerminal }.count
        let reserve = active.multipliedReportingOverflow(by: completionReserveBytes)
        guard !reserve.overflow, encodedBytes <= retention.maxFileBytes else { return false }
        return reserve.partialValue <= retention.maxFileBytes - encodedBytes
    }
    private static func pruned(_ values: [UUID: InvocationReceipt], retention: InvocationRetentionPolicy,
                               now: Date, protecting: Set<UUID>) throws -> [UUID: InvocationReceipt] {
        let eligible = values.values.filter { $0.state.isTerminal && !protecting.contains($0.id) }.sorted {
            let left = $0.finishedAt ?? $0.startedAt, right = $1.finishedAt ?? $1.startedAt
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
        let cutoff = now.addingTimeInterval(-retention.maxFinishedAge)
        var next = values
        var terminalCount = values.values.filter { $0.state.isTerminal }.count
        for receipt in eligible {
            if (receipt.finishedAt ?? receipt.startedAt) < cutoff || terminalCount > retention.maxFinishedCount {
                next[receipt.id] = nil; terminalCount -= 1
            }
        }
        // 精确JSON大小可由单条编码加分隔符计算，避免逐删一条就重编码整库形成平方开销。
        let encoder = JSONEncoder()
        var bytes = try encoded([:]).count
        for receipt in next.values { bytes += try encoder.encode(receipt).count }
        if !next.isEmpty { bytes += next.count - 1 }
        let reserve = next.values.filter { !$0.state.isTerminal }.count * completionReserveBytes
        for receipt in eligible where next[receipt.id] != nil {
            if bytes <= retention.maxFileBytes && reserve <= retention.maxFileBytes - bytes { break }
            bytes -= try encoder.encode(receipt).count
            if next.count > 1 { bytes -= 1 }
            next[receipt.id] = nil
        }
        return next
    }
    private static func boundedName(_ value: String) -> String {
        let bytes = value.utf8
        guard bytes.count > 1_024 else { return value }
        var end = bytes.index(bytes.startIndex, offsetBy: 1_024)
        while end != bytes.startIndex && bytes[end] & 0xc0 == 0x80 { end = bytes.index(before: end) }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
    private static func encoded(_ values: [UUID: InvocationReceipt]) throws -> Data {
        // v3保护预算事实，即使内建只读Agent没有typed runAttempt也不允许旧App忽略后重写。
        try JSONEncoder().encode(Envelope(version: values.values.contains { $0.runTokenBudget != nil } ? 3 : (values.values.contains { $0.runAttempt != nil } ? 2 : 1),
            receipts: values.values.sorted { $0.id.uuidString < $1.id.uuidString }))
    }
    private static func readBounded(directoryFD: Int32, maximum: Int) throws -> Data? {
        let fd = Darwin.openat(directoryFD, fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw InvocationStoreError.invalidFile }
            throw InvocationStoreError.io(errno)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw InvocationStoreError.io(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw InvocationStoreError.invalidFile }
        guard info.st_size <= maximum else { throw InvocationStoreError.loadLimitExceeded }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximum {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximum + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw InvocationStoreError.io(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximum else { throw InvocationStoreError.loadLimitExceeded }
        return data
    }
    private static func persist(_ data: Data, directoryFD: Int32, fault: @Sendable (InvocationPersistencePoint) -> Int32? = { _ in nil }) throws {
        if let code = fault(.beforeWrite) { throw WriteFailure(code: code > 0 ? code : EIO, renamed: false) }
        let temporary = ".invocations-\(UUID().uuidString).tmp"
        let fd = Darwin.openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw WriteFailure(code: errno, renamed: false) }
        var closed = false
        defer { if !closed { Darwin.close(fd) }; _ = Darwin.unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var position = 0
            while position < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: position), buffer.count - position)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw WriteFailure(code: errno, renamed: false) }
                position += count
            }
        }
        guard fsync(fd) == 0 else { throw WriteFailure(code: errno, renamed: false) }
        let closeStatus = Darwin.close(fd); closed = true
        guard closeStatus == 0 else { throw WriteFailure(code: errno, renamed: false) }
        if let code = fault(.beforeRename) { throw WriteFailure(code: code > 0 ? code : EIO, renamed: false) }
        guard Darwin.renameat(directoryFD, temporary, directoryFD, fileName) == 0 else { throw WriteFailure(code: errno, renamed: false) }
        if let code = fault(.afterRename) { throw WriteFailure(code: code > 0 ? code : EIO, renamed: true) }
        guard fsync(directoryFD) == 0 else { throw WriteFailure(code: errno, renamed: true) }
    }
}
