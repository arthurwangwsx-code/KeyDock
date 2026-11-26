import Foundation
import CommandCore
import ExecutionCore
import AgentCore
import AutomationCore
import MacAdapters
import MCPAdapters
import AICore

enum ConfigurationExportSection: String, CaseIterable, Sendable {
    case preferences, definitions, shortcuts, desktop, schedules, resources
    var title: String {
        switch self {
        case .preferences: L("Preferences and clipboard panel")
        case .definitions: L("Saved commands, AI actions and tools")
        case .shortcuts: L("Shortcuts, aliases and favorites")
        case .desktop: L("Application actions and desktop workspaces")
        case .schedules: L("Schedule definitions")
        case .resources: L("AI services, MCP and folder requirements")
        }
    }
}
enum ConfigurationExportError: Error, Sendable, Equatable {
    case noSections, tooLarge, snapshotChanged
    case unavailableSource(String), invalidDefinition(String), invalidReference(String), duplicateDefinition(String)
}
struct ConfigurationExportSource: Sendable {
    let configuration: AppConfiguration
    let applicationActions: [SavedApplicationAction]
    let workspaces: [SavedDesktopWorkspace]
    let desktopSourcesAvailable: Bool
    let schedules: [ScheduleDefinitionExport]
    let primaryAction: ClipboardPrimaryAction
    let separator: ClipboardSeparator
    let sourceVersion: String
}
struct FrozenConfigurationExport: Identifiable, Sendable {
    let id = UUID()
    let sections: Set<ConfigurationExportSection>
    let data: Data
    let preview: String
    let definitionCount: Int
    let externalReferenceCount: Int
    let unselectedDependencyCount: Int
    let requiredLocalFieldCount: Int
}

// 独立格式的显式字段白名单；不编码原始AppConfiguration或账本快照。
struct ConfigurationExportDocument: Encodable {
    let format = "KeyDock.configuration-export"
    let formatVersion = 1
    let sourceVersion: String
    let sections: [String]
    let preferences: ExportPreferences?
    let definitions: ExportDefinitions?
    let shortcuts: ExportShortcuts?
    let desktop: ExportDesktop?
    let schedules: ExportSchedules?
    let resources: ExportResources?
    let excludedFields: [String]
    let requiredLocalFields: [ExportRequirement]
    let externalReferences: [ExportRequirement]
    let unselectedDependencies: [ExportDependency]
}
struct ExportRequirement: Encodable, Sendable, Equatable {
    let owner: String
    let kind: String
    let reference: String
}
struct ExportDependency: Encodable, Sendable, Equatable {
    let owner: String
    let target: String
    let requiredSection: String
}
struct ExportHotkey: Encodable {
    let keyCode: UInt32
    let modifiers: UInt32
}
struct ExportPreferences: Encodable {
    let schemaVersion = 1
    let language: String, appearance: String
    let clipboardRecordingEnabled: Bool, activityRecordingEnabled: Bool
    let taskContentRetentionEnabled: Bool
    let clipboardExclusions: [String]
    let clipboardPrimaryAction: String, clipboardSeparator: String
    let disabledContributions: [String]
}
struct ExportShortcuts: Encodable {
    let schemaVersion = 1
    let launcherShortcut: ExportHotkey?
    let commandShortcuts: [String: ExportHotkey]
    let aiActionShortcuts: [String: ExportHotkey]
    let aliases: [String: String]
    let favorites: [String]
}
struct ExportCommand: Encodable {
    let id: UUID
    let name: String, executable: String
    let arguments: [String]
    let workingDirectory: String
    let timeout: TimeInterval
    let interactive: Bool, shellMode: Bool
    let requiredEnvironmentKeys: [String]
}
struct ExportAIAction: Encodable {
    let id: UUID
    let name: String, builtinKey: String?, prompt: String, input: String, output: String, modelOverride: String
    let scene: AIScene?
    let modelOptions: AIModelOptions?
}
struct ExportAgent: Encodable {
    let id: UUID
    let version: Int
    let name: String, instructions: String, modelOverride: String
    let modelOptions: AIModelOptions?
    let allowedCommandIDs: [UUID], allowedMCPServerIDs: [UUID]
    let allowedMCPToolNames: [String]
    let maxToolCalls: Int, maxTurns: Int, timeoutSeconds: Int
}
struct ExportWorkflowStep: Encodable {
    let id: UUID
    let operation: String
    let targetID: UUID?
    let transform: String?
    let input: String
    let literal: String?
}
struct ExportWorkflow: Encodable {
    let id: UUID
    let name: String
    let version: Int
    let steps: [ExportWorkflowStep]
}
struct ExportSnippet: Encodable { let id: UUID; let name: String; let text: String }
struct ExportWebAction: Encodable { let id: UUID; let name: String; let urlTemplate: String }
struct ExportCollection: Encodable { let id: UUID; let name: String; let commandIDs: [String] }
struct ExportDefinitions: Encodable {
    let schemaVersion = 1
    let commands: [ExportCommand]
    let aiActions: [ExportAIAction]
    let agents: [ExportAgent]
    let workflows: [ExportWorkflow]
    let snippets: [ExportSnippet]
    let webActions: [ExportWebAction]
    let collections: [ExportCollection]
}
struct ExportApplicationAction: Encodable {
    let id: UUID
    let version: Int
    let name: String, applicationID: String, behavior: String
}
struct ExportWorkspaceEntry: Encodable {
    let id: UUID
    let applicationID: String, selector: String, layout: String, display: String, missingApplication: String
}
struct ExportWorkspace: Encodable {
    let id: UUID
    let revision: Int
    let name: String
    let entries: [ExportWorkspaceEntry]
}
struct ExportDesktop: Encodable {
    let schemaVersion = 1
    let applicationActions: [ExportApplicationAction]
    let workspaces: [ExportWorkspace]
}
struct ExportSchedule: Encodable {
    let id: UUID
    let name: String
    let workflowID: UUID
    let enabled: Bool
    let revision: Int
    let trigger: ExportScheduleTrigger
}
struct ExportScheduleTrigger: Encodable {
    let kind: String
    let seconds: TimeInterval?
    let hour: Int?, minute: Int?
    let timeZoneID: String?
}
struct ExportSchedules: Encodable { let schemaVersion = 1; let definitions: [ExportSchedule] }
struct ExportAIService: Encodable {
    let endpoint: String, model: String
    let localHTTP: Bool
    let tokenLimitParameter: String
    let modelSettings: AIModelSettings
    let modelCatalogVersion: String
}
struct ExportStdio: Encodable {
    let executable: String, arguments: [String], workingDirectory: String
    let startupTimeoutSeconds: TimeInterval
}
struct ExportMCPServer: Encodable {
    let id: UUID
    let name: String
    let revision: UUID
    let transportKind: String
    let endpoint: String?
    let stdio: ExportStdio?
    let allowsLocalHTTP: Bool, enabled: Bool
    let protocolVersion: String
    let timeoutSeconds: TimeInterval
}
struct ExportSearchFolder: Encodable { let id: UUID; let name: String }
struct ExportAIRate: Encodable {
    let id: UUID, revision: UUID
    let endpointFingerprint: String, model: String, currency: String
    let inputPerMillion: String, outputPerMillion: String
    let enabled: Bool
    let unitTokens = 1_000_000
}
struct ExportResources: Encodable {
    let schemaVersion = 3
    let aiService: ExportAIService
    let mcpServers: [ExportMCPServer]
    let searchFolders: [ExportSearchFolder]
    let aiRates: [ExportAIRate]
}

struct ConfigurationExportBudget {
    static let maximumBytes = 8 * 1_048_576
    var textBytes = 0
    var definitionCount = 0
    var referenceCount = 0
    mutating func text(_ value: String, maximum: Int = 131_072) throws {
        try Task.checkCancellation()
        let count = value.utf8.count
        guard count <= maximum else { throw ConfigurationExportError.tooLarge }
        let sum = textBytes.addingReportingOverflow(count)
        guard !sum.overflow, sum.partialValue <= Self.maximumBytes else { throw ConfigurationExportError.tooLarge }
        textBytes = sum.partialValue
    }
    mutating func definitions(_ count: Int) throws {
        try Task.checkCancellation()
        let sum = definitionCount.addingReportingOverflow(count)
        guard count >= 0, !sum.overflow, sum.partialValue <= 1024 else { throw ConfigurationExportError.tooLarge }
        definitionCount = sum.partialValue
    }
    mutating func reference() throws {
        try Task.checkCancellation()
        guard referenceCount < 4096 else { throw ConfigurationExportError.tooLarge }
        referenceCount += 1
    }
    func count(_ count: Int, maximum: Int) throws {
        guard count <= maximum else { throw ConfigurationExportError.tooLarge }
    }
}
