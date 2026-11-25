import Foundation
import AutomationCore

private struct ConfigurationExportStamp: Equatable {
    let generation: UUID
    let clipboardRevision: UUID
    let actionsAvailable: Bool
    let workspacesAvailable: Bool
}

extension WorkbenchModel {
    private var configurationExportStamp: ConfigurationExportStamp {
        .init(generation: configurationExportGeneration, clipboardRevision: clipboardPreferences.revision,
            actionsAvailable: applicationActionsWritable && applicationActionStore?.writable == true,
            workspacesAvailable: desktopWorkspacesWritable && desktopWorkspaceStore?.writable == true)
    }

    /// 仅捕获已加载值。异步边界之后核对发布代次，不访问磁盘或重新解析本机资源。
    func captureConfigurationExport(sections: Set<ConfigurationExportSection>, sourceVersion: String,
        scheduleReader: (@Sendable () async -> ScheduleDefinitionExportSnapshot)? = nil) async throws -> ConfigurationExportSource {
        guard !isShuttingDown else { throw CancellationError() }
        let stamp = configurationExportStamp
        let configuration = configuration, actions = applicationActions, workspaces = desktopWorkspaces
        let primaryAction = clipboardPreferences.primaryAction, separator = clipboardPreferences.separator
        let definitions: [ScheduleDefinitionExport]
        if sections.contains(.schedules) {
            let snapshot = if let scheduleReader { await scheduleReader() } else { await scheduleLedger.definitionSnapshot() }
            definitions = snapshot.definitions
        } else { definitions = [] }
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        guard stamp == configurationExportStamp else { throw ConfigurationExportError.snapshotChanged }
        return .init(configuration: configuration, applicationActions: actions, workspaces: workspaces,
            desktopSourcesAvailable: stamp.actionsAvailable && stamp.workspacesAvailable, schedules: definitions,
            primaryAction: primaryAction, separator: separator, sourceVersion: sourceVersion)
    }
}
