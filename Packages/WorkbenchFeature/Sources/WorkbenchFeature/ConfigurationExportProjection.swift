import Foundation
import AICore
import CommandCore
import AutomationCore
import MacAdapters

enum ConfigurationExportProjection {
    static func make(source: ConfigurationExportSource, sections: Set<ConfigurationExportSection>, maximumBytes: Int = ConfigurationExportBudget.maximumBytes) throws -> FrozenConfigurationExport {
        guard !sections.isEmpty else { throw ConfigurationExportError.noSections }
        guard source.configuration.schemaVersion == 1 else { throw ConfigurationExportError.invalidDefinition("configuration.schemaVersion") }
        try Task.checkCancellation()
        var graph = ConfigurationExportGraph(source: source, sections: sections)
        try graph.budget.text(source.sourceVersion, maximum: 128)
        let preferences = try sections.contains(.preferences) ? preferences(source, graph: &graph) : nil
        let definitions = try sections.contains(.definitions) ? definitions(source, graph: &graph) : nil
        let shortcuts = try sections.contains(.shortcuts) ? shortcuts(source, graph: &graph) : nil
        let desktop = try sections.contains(.desktop) ? desktop(source, graph: &graph) : nil
        let schedules = try sections.contains(.schedules) ? schedules(source, graph: &graph) : nil
        let resources = try sections.contains(.resources) ? resources(source, graph: &graph) : nil
        let document = ConfigurationExportDocument(sourceVersion: source.sourceVersion,
            sections: ConfigurationExportSection.allCases.filter(sections.contains).map(\.rawValue),
            preferences: preferences, definitions: definitions, shortcuts: shortcuts, desktop: desktop, schedules: schedules, resources: resources,
            excludedFields: ["Keychain values", "commands[*].environment values", "mcpServers[*].secretReference", "authorization fingerprints and grants", "searchFolders[*].bookmark", "preferences.recent", "clipboard and activity history", "task input, output, drafts and invocation or usage ledgers"],
            requiredLocalFields: graph.required, externalReferences: graph.external, unselectedDependencies: graph.unselected)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try Task.checkCancellation()
        guard maximumBytes > 0, maximumBytes <= ConfigurationExportBudget.maximumBytes, data.count <= maximumBytes else { throw ConfigurationExportError.tooLarge }
        return .init(sections: sections, data: data, preview: String(decoding: data, as: UTF8.self), definitionCount: graph.budget.definitionCount,
            externalReferenceCount: graph.external.count, unselectedDependencyCount: graph.unselected.count, requiredLocalFieldCount: graph.required.count)
    }
    private static func check(_ owner: String, _ body: () throws -> Void) throws {
        do { try body() } catch let value as ConfigurationExportError { throw value }
        catch { throw ConfigurationExportError.invalidDefinition(owner) }
    }
    private static func text(_ value: String, owner: String, maximum: Int, nonempty: Bool = false, path: Bool = false, graph: inout ConfigurationExportGraph) throws {
        try graph.budget.text(value, maximum: maximum)
        guard (!nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), (!path || (value.hasPrefix("/") && !value.utf8.contains(0))) else {
            throw ConfigurationExportError.invalidDefinition(owner)
        }
    }
    private static func hotkey(_ value: HotkeyBinding?, owner: String) throws -> ExportHotkey? {
        guard let value else { return nil }
        guard value.keyCode <= 127, value.modifiers != 0, value.modifiers & ~UInt32(0x1B00) == 0 else { throw ConfigurationExportError.invalidDefinition(owner) }
        return .init(keyCode: value.keyCode, modifiers: value.modifiers)
    }
    private static func preferences(_ source: ConfigurationExportSource, graph: inout ConfigurationExportGraph) throws -> ExportPreferences {
        let c = source.configuration
        guard ["system", "en", "zh-Hans"].contains(c.language), ["system", "light", "dark"].contains(c.appearance) else { throw ConfigurationExportError.invalidDefinition("preferences") }
        try graph.budget.count(c.clipboardExclusions.count, maximum: 1024)
        try graph.budget.count(c.disabledContributions.count, maximum: 64)
        for value in c.clipboardExclusions { try graph.budget.text(value, maximum: 512) }
        for value in c.disabledContributions.sorted() { try graph.budget.text(value, maximum: 512); try graph.resource(owner: "preferences", kind: "toolContribution", reference: value) }
        return .init(language: c.language, appearance: c.appearance, clipboardRecordingEnabled: c.clipboardEnabled, activityRecordingEnabled: c.activityEnabled,
            clipboardExclusions: c.clipboardExclusions, clipboardPrimaryAction: source.primaryAction.rawValue, clipboardSeparator: source.separator.rawValue,
            disabledContributions: c.disabledContributions.sorted())
    }
    private static func shortcuts(_ source: ConfigurationExportSource, graph: inout ConfigurationExportGraph) throws -> ExportShortcuts {
        let c = source.configuration
        try graph.budget.count(c.commandShortcuts.count, maximum: 4096); try graph.budget.count(c.preferences.aliases.count, maximum: 4096)
        try graph.budget.count(c.preferences.favorites.count, maximum: 4096)
        var values: [String: ExportHotkey] = [:]
        var aiShortcuts: [String: ExportHotkey] = [:]
        try graph.budget.count(c.aiActions.count, maximum: 1024)
        for action in c.aiActions where action.shortcut != nil {
            let key = "ai." + action.id.uuidString
            try graph.target(action.id, kind: .ai, owner: "shortcuts.aiActionShortcuts")
            aiShortcuts[key] = try hotkey(action.shortcut, owner: "shortcuts.aiActionShortcuts")
        }
        for key in c.commandShortcuts.keys.sorted() {
            try graph.command(key, owner: "shortcuts.commandShortcuts")
            values[key] = try hotkey(c.commandShortcuts[key], owner: "shortcuts.commandShortcuts")
        }
        for key in c.preferences.aliases.keys.sorted() {
            try graph.command(key, owner: "shortcuts.aliases"); try graph.budget.text(c.preferences.aliases[key]!, maximum: 1024)
        }
        for key in c.preferences.favorites.sorted() { try graph.command(key, owner: "shortcuts.favorites") }
        return .init(launcherShortcut: try hotkey(c.launcherShortcut, owner: "shortcuts.launcherShortcut"), commandShortcuts: values, aiActionShortcuts: aiShortcuts,
            aliases: c.preferences.aliases, favorites: c.preferences.favorites.sorted())
    }
    private static func definitions(_ source: ConfigurationExportSource, graph: inout ConfigurationExportGraph) throws -> ExportDefinitions {
        let c = source.configuration
        try graph.definitions(.command); try graph.definitions(.ai)
        try graph.definitions(.agent, maximum: 32); try graph.definitions(.workflow, maximum: 32)
        try graph.definitions(.snippet, maximum: 200); try graph.definitions(.web, maximum: 100); try graph.definitions(.collection, maximum: 32)
        let commands = try c.savedCommands.map { v -> ExportCommand in
            let owner = "command." + v.id.uuidString
            try text(v.name, owner: owner, maximum: 512, nonempty: true, graph: &graph)
            try text(v.executable, owner: owner, maximum: 4096, path: true, graph: &graph)
            try text(v.workingDirectory, owner: owner, maximum: 4096, path: true, graph: &graph)
            try graph.budget.count(v.arguments.count, maximum: 4096); try graph.budget.count(v.environment.count, maximum: 4096)
            guard v.timeout.isFinite, v.timeout > 0, v.timeout <= 86_400 else { throw ConfigurationExportError.invalidDefinition(owner) }
            for argument in v.arguments {
                try graph.budget.text(argument, maximum: 1_048_576)
                guard !argument.utf8.contains(0) else { throw ConfigurationExportError.invalidDefinition(owner) }
            }
            let keys = v.environment.keys.sorted()
            for key in keys {
                guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0) else { throw ConfigurationExportError.invalidDefinition(owner) }
                try graph.budget.text(key, maximum: 256)
                try graph.local(owner: owner, kind: "environmentValue", reference: key)
            }
            try graph.resource(owner: owner, kind: "executable", reference: v.executable)
            try graph.resource(owner: owner, kind: "workingDirectory", reference: v.workingDirectory)
            return .init(id: v.id, name: v.name, executable: v.executable, arguments: v.arguments, workingDirectory: v.workingDirectory,
                timeout: v.timeout, interactive: v.interactive, shellMode: v.shellMode, requiredEnvironmentKeys: keys)
        }
        let actions = try c.aiActions.map { v -> ExportAIAction in
            let owner = "ai." + v.id.uuidString
            try text(v.name, owner: owner, maximum: 512, nonempty: true, graph: &graph)
            try graph.budget.text(v.prompt, maximum: 1_048_576); try graph.budget.text(v.modelOverride, maximum: 512)
            if let key = v.builtinKey { try graph.budget.text(key, maximum: 512) }
            try graph.aiService(owner: owner)
            return .init(id: v.id, name: v.name, builtinKey: v.builtinKey, prompt: v.prompt, input: v.input.rawValue, output: v.output.rawValue,
                modelOverride: v.modelOverride)
        }
        let agents = try c.agents.map { v -> ExportAgent in
            let owner = "agent." + v.id.uuidString
            try check(owner) { try v.validate() }
            try graph.aiService(owner: owner)
            try graph.budget.text(v.name, maximum: 512); try graph.budget.text(v.instructions, maximum: 32_768); try graph.budget.text(v.modelOverride, maximum: 512)
            for id in v.allowedCommandIDs.sorted(by: { $0.uuidString < $1.uuidString }) { try graph.target(id, kind: .command, owner: owner) }
            for id in v.allowedMCPServerIDs.sorted(by: { $0.uuidString < $1.uuidString }) { try graph.target(id, kind: .mcp, owner: owner) }
            for name in v.allowedMCPToolNames.sorted() { try graph.mcpTool(name, allowedSources: v.allowedMCPServerIDs, owner: owner) }
            return .init(id: v.id, version: v.version, name: v.name, instructions: v.instructions, modelOverride: v.modelOverride,
                allowedCommandIDs: v.allowedCommandIDs.sorted { $0.uuidString < $1.uuidString }, allowedMCPServerIDs: v.allowedMCPServerIDs.sorted { $0.uuidString < $1.uuidString },
                allowedMCPToolNames: v.allowedMCPToolNames.sorted(), maxToolCalls: v.maxToolCalls, maxTurns: v.maxTurns, timeoutSeconds: v.timeoutSeconds)
        }
        let workflows = try c.workflows.map { v -> ExportWorkflow in
            let owner = "workflow." + v.id.uuidString
            try check(owner) { _ = try WorkflowCompiler.compile(v, availableCommandIDs: Set(c.savedCommands.map(\.id)), availableAIActionIDs: Set(c.aiActions.map(\.id)), allowsInteraction: true) }
            try graph.budget.text(v.name, maximum: 200)
            let steps = try v.steps.map { step -> ExportWorkflowStep in
                let operation: String, target: UUID?, transform: String?
                switch step.operation {
                case .savedCommand(let id):
                    operation = "savedCommand"; target = id; transform = nil; try graph.target(id, kind: .command, owner: owner)
                    guard let command = c.savedCommands.first(where: { $0.id == id }), !command.interactive,
                          !(command.shellMode && command.arguments.contains("{{input}}")) else { throw ConfigurationExportError.invalidDefinition(owner) }
                case .aiAction(let id): operation = "aiAction"; target = id; transform = nil; try graph.target(id, kind: .ai, owner: owner)
                case .transform(let value): operation = "transform"; target = nil; transform = value.rawValue
                case .manualInput: operation = "manualInput"; target = nil; transform = nil
                }
                let input: String, literal: String?
                switch step.input {
                case .workflowInput: input = "workflowInput"; literal = nil
                case .previousOutput: input = "previousOutput"; literal = nil
                case .literal(let value): input = "literal"; literal = value; try graph.budget.text(value)
                }
                return .init(id: step.id, operation: operation, targetID: target, transform: transform, input: input, literal: literal)
            }
            return .init(id: v.id, name: v.name, version: v.version, steps: steps)
        }
        let snippets = try c.snippets.map { v -> ExportSnippet in
            try check("snippet." + v.id.uuidString) { _ = try SnippetDefinition(id: v.id, name: v.name, text: v.text) }
            try graph.budget.text(v.name, maximum: 200); try graph.budget.text(v.text, maximum: 65_536)
            return .init(id: v.id, name: v.name, text: v.text)
        }
        let web = try c.webActions.map { v -> ExportWebAction in
            try check("web." + v.id.uuidString) { try v.validate() }
            try graph.budget.text(v.name, maximum: 200); try graph.budget.text(v.urlTemplate, maximum: 4096)
            try graph.resource(owner: "web." + v.id.uuidString, kind: "urlTemplate", reference: v.urlTemplate)
            return .init(id: v.id, name: v.name, urlTemplate: v.urlTemplate)
        }
        let collections = try c.collections.map { v -> ExportCollection in
            let owner = "collection." + v.id.uuidString
            try check(owner) { try v.validate() }; try graph.budget.text(v.name, maximum: 200)
            for reference in v.commandIDs { try graph.command(reference, owner: owner, collectionRole: true) }
            return .init(id: v.id, name: v.name, commandIDs: v.commandIDs)
        }
        return .init(commands: commands, aiActions: actions, agents: agents, workflows: workflows, snippets: snippets, webActions: web, collections: collections)
    }
    private static func desktop(_ source: ConfigurationExportSource, graph: inout ConfigurationExportGraph) throws -> ExportDesktop {
        guard source.desktopSourcesAvailable else { throw ConfigurationExportError.unavailableSource("desktop") }
        try graph.definitions(.applicationAction, maximum: 100); try graph.definitions(.workspace, maximum: 32)
        let actions = try source.applicationActions.map { v -> ExportApplicationAction in
            let owner = "application-action." + v.id.uuidString
            try check(owner) { _ = try SavedApplicationAction(id: v.id, version: v.version, name: v.name, applicationID: v.applicationID, behavior: v.behavior) }
            try graph.budget.text(v.name, maximum: 160); try graph.command(v.applicationID, owner: owner)
            return .init(id: v.id, version: v.version, name: v.name, applicationID: v.applicationID, behavior: v.behavior.rawValue)
        }
        let workspaces = try source.workspaces.map { v -> ExportWorkspace in
            let owner = "desktop-workspace." + v.id.uuidString
            try check(owner) { _ = try SavedDesktopWorkspace(id: v.id, revision: v.revision, name: v.name, entries: v.entries) }
            try graph.budget.text(v.name, maximum: 160)
            let entries = try v.entries.map { entry -> ExportWorkspaceEntry in
                try graph.command(entry.applicationID, owner: owner)
                return .init(id: entry.id, applicationID: entry.applicationID, selector: entry.selector.rawValue, layout: entry.layout.rawValue,
                    display: entry.display.rawValue, missingApplication: entry.missingApplication.rawValue)
            }
            return .init(id: v.id, revision: v.revision, name: v.name, entries: entries)
        }
        return .init(applicationActions: actions, workspaces: workspaces)
    }
    private static func schedules(_ source: ConfigurationExportSource, graph: inout ConfigurationExportGraph) throws -> ExportSchedules {
        try graph.definitions(.schedule, maximum: 200)
        let values = try source.schedules.map { v -> ExportSchedule in
            let owner = "schedule." + v.id.uuidString
            try text(v.name, owner: owner, maximum: 200, nonempty: true, graph: &graph)
            guard v.revision > 0 else { throw ConfigurationExportError.invalidDefinition(owner) }
            try check(owner) { try ScheduleCalendar.validate(v.trigger) }
            try graph.target(v.workflowID, kind: .workflow, owner: owner)
            let trigger: ExportScheduleTrigger
            switch v.trigger {
            case .interval(let seconds): trigger = .init(kind: "interval", seconds: seconds, hour: nil, minute: nil, timeZoneID: nil)
            case .daily(let hour, let minute, let zone):
                try graph.budget.text(zone, maximum: 100); trigger = .init(kind: "daily", seconds: nil, hour: hour, minute: minute, timeZoneID: zone)
            }
            return .init(id: v.id, name: v.name, workflowID: v.workflowID, enabled: v.enabled, revision: v.revision, trigger: trigger)
        }
        return .init(definitions: values)
    }
    private static func resources(_ source: ConfigurationExportSource, graph: inout ConfigurationExportGraph) throws -> ExportResources {
        let c = source.configuration
        try graph.definitions(.mcp, maximum: 8); try graph.definitions(.folder, maximum: 8)
        try graph.definitions(.rate, maximum: 64)
        var rateIdentities: Set<String> = []
        let rates = try c.aiRates.map { value -> ExportAIRate in
            let owner = "ai-rate." + value.id.uuidString
            guard value.isValid, rateIdentities.insert(value.endpointFingerprint + "|" + Data(value.model.utf8).base64EncodedString()).inserted else { throw ConfigurationExportError.invalidDefinition(owner) }
            for text in [value.endpointFingerprint, value.model, value.currency, value.inputPerMillion, value.outputPerMillion] { try graph.budget.text(text, maximum: 256) }
            if URL(string: c.endpoint).map({ AIServiceIdentity.fingerprint($0) }) != value.endpointFingerprint {
                try graph.local(owner: owner, kind: "serviceBinding", reference: "Configure the matching API endpoint")
            }
            return .init(id: value.id, revision: value.revision, endpointFingerprint: value.endpointFingerprint, model: value.model, currency: value.currency,
                         inputPerMillion: value.inputPerMillion, outputPerMillion: value.outputPerMillion, enabled: value.enabled)
        }
        try graph.budget.text(c.endpoint, maximum: 4096); try graph.budget.text(c.model, maximum: 512)
        guard ["max_tokens", "max_completion_tokens"].contains(c.tokenLimitParameter) else { throw ConfigurationExportError.invalidDefinition("resources.aiService") }
        if !c.endpoint.isEmpty {
            guard let url = URL(string: c.endpoint) else { throw ConfigurationExportError.invalidDefinition("resources.aiService") }
            try check("resources.aiService") { try AIProviderConfiguration(endpoint: url, model: c.model.isEmpty ? "unconfigured" : c.model, allowsLocalHTTP: c.localHTTP).validate() }
            try graph.resource(owner: "aiService", kind: "apiEndpoint", reference: c.endpoint)
        } else { try graph.local(owner: "aiService", kind: "serviceConfiguration", reference: "endpoint") }
        if c.model.isEmpty { try graph.local(owner: "aiService", kind: "serviceConfiguration", reference: "model") }
        try graph.local(owner: "aiService", kind: "credential", reference: "apiKeyIfRequiredByService")
        let servers = try c.mcpServers.map { v -> ExportMCPServer in
            let owner = "mcp-server." + v.id.uuidString
            try text(v.name, owner: owner, maximum: 256, nonempty: true, graph: &graph)
            guard v.timeoutSeconds.isFinite, (1...120).contains(v.timeoutSeconds) else { throw ConfigurationExportError.invalidDefinition(owner) }
            let stdio: ExportStdio?, endpoint: String?
            if v.transportKind == .http {
                try check(owner) { try v.validate() }
                endpoint = v.endpoint.absoluteString; stdio = nil
                try graph.resource(owner: owner, kind: "mcpEndpoint", reference: endpoint!)
            } else {
                // 不调用stdio.validate：其磁盘访问不属于定义导出。
                guard let launch = v.stdioLaunch, v.endpoint.isFileURL, v.endpoint.path.utf8.elementsEqual(launch.executable.utf8), v.secretReference == nil,
                      !v.allowsLocalHTTP, launch.startupTimeoutSeconds.isFinite, (1...120).contains(launch.startupTimeoutSeconds) else { throw ConfigurationExportError.invalidDefinition(owner) }
                try text(launch.executable, owner: owner, maximum: 4096, path: true, graph: &graph)
                try text(launch.workingDirectory, owner: owner, maximum: 4096, path: true, graph: &graph)
                try graph.budget.count(launch.arguments.count, maximum: 128)
                var bytes = 0
                for argument in launch.arguments {
                    try graph.budget.text(argument, maximum: 16_384)
                    guard !argument.utf8.contains(0), bytes <= 16_384 - argument.utf8.count else { throw ConfigurationExportError.invalidDefinition(owner) }
                    bytes += argument.utf8.count
                }
                try graph.resource(owner: owner, kind: "stdioExecutable", reference: launch.executable)
                try graph.resource(owner: owner, kind: "workingDirectory", reference: launch.workingDirectory)
                stdio = .init(executable: launch.executable, arguments: launch.arguments, workingDirectory: launch.workingDirectory, startupTimeoutSeconds: launch.startupTimeoutSeconds)
                endpoint = nil
            }
            if v.secretReference != nil { try graph.local(owner: owner, kind: "credential", reference: "bearerToken") }
            return .init(id: v.id, name: v.name, revision: v.revision, transportKind: v.transportKind.rawValue, endpoint: endpoint, stdio: stdio,
                allowsLocalHTTP: v.allowsLocalHTTP, enabled: v.enabled, protocolVersion: v.protocolVersion.rawValue, timeoutSeconds: v.timeoutSeconds)
        }
        let folders = try c.searchFolders.map { v -> ExportSearchFolder in
            try graph.budget.text(v.name, maximum: 512)
            try graph.local(owner: "search-folder." + v.id.uuidString, kind: "folderSelection", reference: "Choose the folder again")
            return .init(id: v.id, name: v.name)
        }
        return .init(aiService: .init(endpoint: c.endpoint, model: c.model, localHTTP: c.localHTTP, tokenLimitParameter: c.tokenLimitParameter), mcpServers: servers, searchFolders: folders, aiRates: rates)
    }
}
