import Foundation
import AutomationCore
import MCPAdapters

enum SavedSourceTarget: Equatable, Sendable {
    case workflow(UUID), mcpServer(UUID)
    var id: UUID { switch self { case .workflow(let id), .mcpServer(let id): id } }
    var isWorkflow: Bool { if case .workflow = self { true } else { false } }
}

struct SourceRemovalReview: Identifiable {
    let id = UUID()
    let target: SavedSourceTarget
    let name: String
    let fingerprint: String
    let dependencies: [SavedItemDependency]
    let dependencyFingerprint: String
    let scheduleGeneration: UUID?
}

enum SourceRemovalError: Error, Equatable {
    case unavailable, changed, inUse, busy
    case persistence(LocalizedNotice), mcpPersistencePaused(LocalizedNotice)
}

/// 来源命名空间是已保存的工具身份；不查询远端目录，也不把提示词中的文字视为引用。
enum MCPToolReference {
    static func prefix(_ id: UUID) -> String { "mcp_" + String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)) + "_" }
    static func references(_ name: String, sourceID: UUID) -> Bool { name.hasPrefix(prefix(sourceID)) }
    static func validName(_ name: String) -> Bool {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        func hex(_ part: Substring, count: Int) -> Bool { part.utf8.count == count && part.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        return parts.count == 3 && parts[0] == "mcp" && hex(parts[1], count: 12) && hex(parts[2], count: 16)
    }
}

extension WorkbenchModel {
    // owner先于Published状态占位，避免同步订阅者在willSet中重入。
    func beginScheduleMutation() -> UUID? {
        guard !isDesktopReview, !isShuttingDown, scheduleMutationOwner == nil, !scheduleBusy else { return nil }
        let owner = UUID(); scheduleMutationOwner = owner; scheduleBusy = true; return owner
    }
    func finishScheduleMutation(_ owner: UUID) {
        guard scheduleMutationOwner == owner else { return }
        scheduleBusy = false; scheduleMutationOwner = nil
    }
    func beginMCPSettingsMutation() -> UUID? {
        guard !isDesktopReview, !isShuttingDown, mcpSettingsOwner == nil, !mcpSettingsChanging else { return nil }
        let owner = UUID(); mcpSettingsOwner = owner; mcpSettingsChanging = true; return owner
    }
    func finishMCPSettingsMutation(_ owner: UUID) {
        guard mcpSettingsOwner == owner else { return }
        mcpSettingsChanging = false; mcpSettingsOwner = nil
    }

    func reviewSourceRemoval(_ target: SavedSourceTarget,
        scheduleReader: (@Sendable () async -> ScheduleDefinitionExportSnapshot)? = nil) async throws -> SourceRemovalReview {
        guard !isShuttingDown else { throw CancellationError() }
        let stamp = configurationExportGeneration
        let snapshot: ScheduleDefinitionExportSnapshot?
        if target.isWorkflow {
            snapshot = if let scheduleReader { await scheduleReader() } else { await scheduleLedger.definitionSnapshot() }
        } else { snapshot = nil }
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        guard stamp == configurationExportGeneration else { throw SourceRemovalError.changed }
        return try sourceRemovalSnapshot(target, schedules: snapshot)
    }

    private func sourceRemovalSnapshot(_ target: SavedSourceTarget, schedules: ScheduleDefinitionExportSnapshot?) throws -> SourceRemovalReview {
        let name: String, signature: String
        var references: [SavedItemDependency] = []
        switch target {
        case .workflow(let id):
            guard configuration.workflows.filter({ $0.id == id }).count == 1 else { throw SourceRemovalError.unavailable }
            guard let value = configuration.workflows.first(where: { $0.id == id }), let digest = objectFingerprint(value), let schedules else { throw SourceRemovalError.unavailable }
            name = value.name; signature = digest
            references += schedules.definitions.filter { $0.workflowID == id }.map { .init(kind: .schedule, objectID: $0.id, name: $0.name) }
            let key = "workflow." + id.uuidString
            references += configuration.collections.filter { $0.commandIDs.contains(key) }.map { .init(kind: .collection, objectID: $0.id, name: $0.name) }
        case .mcpServer(let id):
            guard configuration.mcpServers.filter({ $0.id == id }).count == 1 else { throw SourceRemovalError.unavailable }
            guard let value = configuration.mcpServers.first(where: { $0.id == id }), let digest = objectFingerprint(value) else { throw SourceRemovalError.unavailable }
            name = value.name; signature = digest
            references += configuration.agents.filter { $0.allowedMCPServerIDs.contains(id) || $0.allowedMCPToolNames.contains(where: { MCPToolReference.references($0, sourceID: id) }) }
                .map { .init(kind: .agent, objectID: $0.id, name: $0.name) }
        }
        references.sort { $0.id < $1.id }
        guard let digest = objectFingerprint(references) else { throw SourceRemovalError.unavailable }
        return .init(target: target, name: name, fingerprint: signature, dependencies: references, dependencyFingerprint: digest, scheduleGeneration: schedules?.generation)
    }

    /// 最终检查之后同步提交主配置；跨actor部分由共同owner门禁保护。
    func removeSource(_ review: SourceRemovalReview, isCurrent: @escaping @MainActor () -> Bool,
        scheduleReader: (@Sendable () async -> ScheduleDefinitionExportSnapshot)? = nil) async throws {
        try await removeSourceTracked(review, isCurrent: isCurrent, scheduleReader: scheduleReader)
    }
    private func removeSourceTracked(_ review: SourceRemovalReview, isCurrent: @escaping @MainActor () -> Bool,
        scheduleReader: (@Sendable () async -> ScheduleDefinitionExportSnapshot)?) async throws {
        guard !isShuttingDown, !Task.isCancelled, isCurrent() else { throw CancellationError() }
        let id = UUID()
        let worker = Task { @MainActor () -> Result<Void, Error> in
            defer { configurationOperations[id] = nil }
            do { try await removeSourceImpl(review, isCurrent: isCurrent, scheduleReader: scheduleReader); return .success(()) }
            catch { return .failure(error) }
        }
        trackConfigurationOperation(worker, id: id)
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        try result.get()
    }
    private func removeSourceImpl(_ review: SourceRemovalReview, isCurrent: @MainActor () -> Bool,
        scheduleReader: (@Sendable () async -> ScheduleDefinitionExportSnapshot)?) async throws {
        guard !isShuttingDown, isCurrent() else { throw CancellationError() }
        switch review.target {
        case .workflow(let id):
            guard let owner = beginScheduleMutation() else { throw SourceRemovalError.busy }
            defer { finishScheduleMutation(owner) }
            let stamp = configurationExportGeneration
            let snapshot = if let scheduleReader { await scheduleReader() } else { await scheduleLedger.definitionSnapshot() }
            try Task.checkCancellation()
            guard !isShuttingDown, isCurrent() else { throw CancellationError() }
            guard stamp == configurationExportGeneration, snapshot.generation == review.scheduleGeneration else { throw SourceRemovalError.changed }
            try validateSourceRemoval(review, current: sourceRemovalSnapshot(review.target, schedules: snapshot))
            var next = configuration; next.workflows.removeAll { $0.id == id }
            let key = "workflow." + id.uuidString
            next.commandShortcuts[key] = nil; next.preferences.favorites.remove(key)
            next.preferences.aliases[key] = nil; next.preferences.recent[key] = nil
            guard commitShortcutConfiguration(next) else { throw SourceRemovalError.persistence(settingsNoticeMessage) }
            workspaceNoticeMessage = .none
        case .mcpServer(let id):
            guard let owner = beginMCPSettingsMutation() else { throw SourceRemovalError.busy }
            defer { finishMCPSettingsMutation(owner) }
            try validateSourceRemoval(review, current: sourceRemovalSnapshot(review.target, schedules: nil))
            guard !isShuttingDown, isCurrent(), !Task.isCancelled else { throw CancellationError() }
            // 真正提交确认后保持撤权意图；文件失败不能重新开启本会话的来源。
            mcpSessionDisabled.insert(id)
            var next = configuration; next.mcpServers.removeAll { $0.id == id }
            let saved = commitSettingsConfiguration(next), failure = settingsNoticeMessage
            await invalidateMCPSource(id)
            guard saved else { throw SourceRemovalError.mcpPersistencePaused(failure) }
        }
    }
    private func validateSourceRemoval(_ reviewed: SourceRemovalReview, current: SourceRemovalReview) throws {
        guard current.fingerprint == reviewed.fingerprint, current.dependencyFingerprint == reviewed.dependencyFingerprint else { throw SourceRemovalError.changed }
        guard current.dependencies.isEmpty else { throw SourceRemovalError.inUse }
    }
}
