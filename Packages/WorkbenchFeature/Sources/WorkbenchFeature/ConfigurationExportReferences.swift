import Foundation
import CommandCore

enum ExportDefinitionKind: String {
    case command, ai, agent, workflow, snippet, web, collection
    case applicationAction = "application-action", workspace = "desktop-workspace", schedule, mcp = "mcp-server", folder = "search-folder", rate = "ai-rate"
    var section: ConfigurationExportSection {
        switch self {
        case .command, .ai, .agent, .workflow, .snippet, .web, .collection: .definitions
        case .applicationAction, .workspace: .desktop
        case .schedule: .schedules
        case .mcp, .folder, .rate: .resources
        }
    }
    var isCommand: Bool { ![Self.agent, .schedule, .mcp, .folder, .rate].contains(self) }
}

/// 仅检查冻结定义图。资源存在、服务目录和执行授权都不由此证明。
struct ConfigurationExportGraph {
    let source: ConfigurationExportSource
    let sections: Set<ConfigurationExportSection>
    var budget = ConfigurationExportBudget()
    var external: [ExportRequirement] = []
    var required: [ExportRequirement] = []
    var unselected: [ExportDependency] = []
    private var indices: [ExportDefinitionKind: Set<UUID>] = [:]
    init(source: ConfigurationExportSource, sections: Set<ConfigurationExportSection>) { self.source = source; self.sections = sections }

    mutating func definitions(_ kind: ExportDefinitionKind, maximum: Int = 1024) throws {
        let count = count(kind)
        try budget.count(count, maximum: maximum)
        try budget.definitions(count)
        _ = try index(kind)
    }
    private func count(_ kind: ExportDefinitionKind) -> Int {
        let c = source.configuration
        return switch kind {
        case .command: c.savedCommands.count
        case .ai: c.aiActions.count
        case .agent: c.agents.count
        case .workflow: c.workflows.count
        case .snippet: c.snippets.count
        case .web: c.webActions.count
        case .collection: c.collections.count
        case .applicationAction: source.applicationActions.count
        case .workspace: source.workspaces.count
        case .schedule: source.schedules.count
        case .mcp: c.mcpServers.count
        case .folder: c.searchFolders.count
        case .rate: c.aiRates.count
        }
    }
    private func ids(_ kind: ExportDefinitionKind) -> [UUID] {
        let c = source.configuration
        switch kind {
        case .command: return c.savedCommands.map(\.id)
        case .ai: return c.aiActions.map(\.id)
        case .agent: return c.agents.map(\.id)
        case .workflow: return c.workflows.map(\.id)
        case .snippet: return c.snippets.map(\.id)
        case .web: return c.webActions.map(\.id)
        case .collection: return c.collections.map(\.id)
        case .applicationAction: return source.applicationActions.map(\.id)
        case .workspace: return source.workspaces.map(\.id)
        case .schedule: return source.schedules.map(\.id)
        case .mcp: return c.mcpServers.map(\.id)
        case .folder: return c.searchFolders.map(\.id)
        case .rate: return c.aiRates.map(\.id)
        }
    }
    private mutating func index(_ kind: ExportDefinitionKind) throws -> Set<UUID> {
        if let cached = indices[kind] { return cached }
        if kind.section == .desktop, !source.desktopSourcesAvailable { throw ConfigurationExportError.unavailableSource("desktop") }
        try budget.count(count(kind), maximum: 1024)
        let values = ids(kind)
        let set = Set(values)
        guard set.count == values.count else { throw ConfigurationExportError.duplicateDefinition(kind.rawValue) }
        indices[kind] = set
        return set
    }
    mutating func target(_ id: UUID, kind: ExportDefinitionKind, owner: String) throws {
        try budget.reference()
        guard try index(kind).contains(id) else { throw ConfigurationExportError.invalidReference(owner) }
        if !sections.contains(kind.section) {
            unselected.append(.init(owner: owner, target: kind.rawValue + "." + id.uuidString, requiredSection: kind.section.rawValue))
        }
    }
    mutating func resource(owner: String, kind: String, reference: String) throws {
        try budget.reference(); try budget.text(reference, maximum: 8192)
        external.append(.init(owner: owner, kind: kind, reference: reference))
    }
    mutating func local(owner: String, kind: String, reference: String) throws {
        try budget.reference(); try budget.text(reference, maximum: 4096)
        required.append(.init(owner: owner, kind: kind, reference: reference))
    }
    mutating func aiService(owner: String) throws {
        try budget.reference()
        if !sections.contains(.resources) { unselected.append(.init(owner: owner, target: "ai-service.global", requiredSection: "resources")) }
    }
    mutating func command(_ value: String, owner: String, collectionRole: Bool = false) throws {
        try budget.text(value, maximum: 4096)
        if value.hasPrefix("app.") {
            guard DesktopWorkspaceEntry.validApplicationID(value) else { throw ConfigurationExportError.invalidReference(owner) }
            try resource(owner: owner, kind: "application", reference: value)
            return
        }
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let kind = ExportDefinitionKind(rawValue: String(parts[0])), kind.isCommand, let id = UUID(uuidString: String(parts[1])), id.uuidString == parts[1] {
            guard !collectionRole || kind != .collection else { throw ConfigurationExportError.invalidReference(owner) }
            try target(id, kind: kind, owner: owner); return
        }
        let builtins: Set<String> = ["clipboard", "tasks", "commands", "ai", "agent", "settings", "activity", "workflows", "tools", "capture", "desktop-workspaces"]
        let builtin = parts.count == 2 && parts[0] == "utility" && builtins.contains(String(parts[1]))
        let layout = value.hasPrefix("utility.window-layout.") && WindowLayout(rawValue: String(value.dropFirst("utility.window-layout.".count))) != nil
        let window = value.hasPrefix("utility.window-command.") && WindowCommand(rawValue: String(value.dropFirst("utility.window-command.".count))) != nil
        guard builtin || ((!collectionRole) && (layout || window)) else { throw ConfigurationExportError.invalidReference(owner) }
        try resource(owner: owner, kind: "builtinCommand", reference: value)
    }
    mutating func mcpTool(_ name: String, allowedSources: Set<UUID>, owner: String) throws {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        func hex(_ text: Substring, count: Int) -> Bool { text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard parts.count == 3, parts[0] == "mcp", hex(parts[1], count: 12), hex(parts[2], count: 16) else { throw ConfigurationExportError.invalidReference(owner) }
        let matches = allowedSources.filter { $0.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12) == parts[1] }
        guard matches.count == 1 else { throw ConfigurationExportError.invalidReference(owner) }
        try resource(owner: owner, kind: "requiresCatalogRevalidation", reference: name)
    }
}
