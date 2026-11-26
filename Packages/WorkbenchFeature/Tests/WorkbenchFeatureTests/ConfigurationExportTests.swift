import Foundation
import Testing
import CommandCore
import ExecutionCore
import AgentCore
import AutomationCore
import MCPAdapters
import MacAdapters
@testable import WorkbenchFeature

enum ConfigurationExportFixture {
    static let commandID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let actionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let serverID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let workflowID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let text = "e\u{301} / é / 中文 👨‍👩‍👧‍👦\n\t\\\""
    static func source(_ configuration: AppConfiguration? = nil, available: Bool = true) throws -> ConfigurationExportSource {
        var c = AppConfiguration(); c.agents = []
        c.savedCommands = [.init(id: commandID, name: "Synthetic CLI", executable: "/synthetic/missing/tool", arguments: ["--value", text, ""], workingDirectory: "/synthetic/missing", environment: ["TOKEN": "SECRET_ENV_SENTINEL"]) ]
        var action = AIActionPreset(name: "Synthetic AI", prompt: text); action.id = actionID; action.shortcut = .init()
        c.aiActions = [action]
        c.mcpServers = [.init(id: serverID, name: "Synthetic MCP", endpoint: URL(string: "https://example.com/mcp")!, secretReference: "SECRET_REFERENCE_SENTINEL")]
        var agent = AgentDefinition(); agent.allowedCommandIDs = [commandID]; agent.allowedMCPServerIDs = [serverID]
        agent.allowedMCPToolNames = ["mcp_333333333333_abcdef0123456789"]; c.agents = [agent]
        c.workflows = [.init(id: workflowID, name: "Synthetic flow", steps: [.init(operation: .savedCommand(commandID), input: .literal(text)), .init(operation: .aiAction(actionID))])]
        c.snippets = [try .init(name: "Synthetic snippet", text: text)]
        c.webActions = [try .init(name: "Synthetic web", urlTemplate: "https://example.com/?q={query}")]
        c.collections = [try .init(name: "Synthetic collection", commandIDs: ["ai." + actionID.uuidString, "command." + commandID.uuidString])]
        c.searchFolders = [.init(id: UUID(), name: "Synthetic folder", bookmark: Data("SECRET_BOOKMARK_SENTINEL".utf8))]
        c.preferences.aliases["command." + commandID.uuidString] = text
        c.preferences.favorites = ["ai." + actionID.uuidString]
        c.preferences.recent["SECRET_RECENT_SENTINEL"] = Date()
        let application = "app./synthetic/Missing.app"
        c.savedApplicationActions = [try .init(name: "Synthetic app", applicationID: application, behavior: .requestQuit)]
        let selected = configuration ?? c
        return .init(configuration: selected,
            applicationActions: selected.savedApplicationActions ?? [],
            workspaces: [try .init(revision: 3, name: "Synthetic workspace", entries: [.init(applicationID: application, layout: .leftHalf)])],
            desktopSourcesAvailable: available,
            schedules: [.init(id: UUID(), name: "Synthetic schedule", workflowID: workflowID, enabled: true, trigger: .daily(hour: 9, minute: 30, timeZoneID: "Asia/Kuala_Lumpur"), revision: 2)],
            primaryAction: .copy, separator: .blankLine, sourceVersion: "synthetic-test")
    }
    static func object(_ value: FrozenConfigurationExport) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: value.data) as? [String: Any])
    }
}

struct ConfigurationExportProjectionTests {
    private let all = Set(ConfigurationExportSection.allCases)
    @Test(arguments: [nil, 34] as [Int?]) func definitionsV2ExportsExplicitNullableTokenThreshold(_ threshold: Int?) throws {
        var configuration = AppConfiguration(); configuration.agents[0].maxRunTokens = threshold
        let source = try ConfigurationExportFixture.source(configuration)
        let frozen = try ConfigurationExportProjection.make(source: source, sections: [.definitions])
        let document = try ConfigurationExportFixture.object(frozen)
        let definitions = try #require(document["definitions"] as? [String: Any]), agents = try #require(definitions["agents"] as? [[String: Any]])
        #expect(definitions["schemaVersion"] as? Int == 2)
        if let threshold { #expect(agents[0]["maxRunTokens"] as? Int == threshold) }
        else { #expect(agents[0]["maxRunTokens"] is NSNull) }
    }
    @Test func contentRetentionPreferenceIsExportedWithoutAnyTaskBody() throws {
        var configuration = AppConfiguration(); configuration.taskMaterialRetentionEnabled = true
        let source = try ConfigurationExportFixture.source(configuration)
        let frozen = try ConfigurationExportProjection.make(source: source, sections: [.preferences])
        let object = try ConfigurationExportFixture.object(frozen)
        let preferences = try #require(object["preferences"] as? [String: Any])
        #expect(preferences["taskContentRetentionEnabled"] as? Bool == true)
        for field in ["input", "output", "taskMaterialBuffers", "successfulCheckpoint", "taskMaterialHandles"] { #expect(preferences[field] == nil) }
    }
    @Test func fullDocumentUsesExplicitFieldsAndPreservesUTF8AndOrderedDefinitions() throws {
        let source = try ConfigurationExportFixture.source()
        let frozen = try ConfigurationExportProjection.make(source: source, sections: all)
        let root = try ConfigurationExportFixture.object(frozen)
        #expect(root["format"] as? String == "KeyDock.configuration-export")
        #expect(root["formatVersion"] as? Int == 1)
        #expect(root["sections"] as? [String] == ["preferences", "definitions", "shortcuts", "desktop", "schedules", "resources"])
        let definitions = try #require(root["definitions"] as? [String: Any])
        #expect(Set(definitions.keys) == ["schemaVersion", "commands", "aiActions", "agents", "workflows", "snippets", "webActions", "collections"])
        let command = try #require((definitions["commands"] as? [[String: Any]])?.first)
        #expect(Set(command.keys) == ["id", "name", "executable", "arguments", "workingDirectory", "timeout", "interactive", "shellMode", "requiredEnvironmentKeys"])
        #expect(command["id"] as? String == "11111111-1111-4111-8111-111111111111")
        let arguments = try #require(command["arguments"] as? [String])
        #expect(arguments.count == 3 && arguments[0] == "--value" && arguments[2].isEmpty)
        #expect(arguments[1].utf8.elementsEqual(ConfigurationExportFixture.text.utf8))
        #expect(command["requiredEnvironmentKeys"] as? [String] == ["TOKEN"])
        let collections = try #require(definitions["collections"] as? [[String: Any]])
        #expect(collections.first?["commandIDs"] as? [String] == ["ai.22222222-2222-4222-8222-222222222222", "command.11111111-1111-4111-8111-111111111111"])
        #expect(frozen.preview.utf8.elementsEqual(frozen.data))
        #expect(frozen.unselectedDependencyCount == 0 && frozen.definitionCount == 12)
        for sentinel in ["SECRET_ENV_SENTINEL", "SECRET_REFERENCE_SENTINEL", "SECRET_BOOKMARK_SENTINEL", "SECRET_RECENT_SENTINEL"] { #expect(!frozen.preview.contains(sentinel)) }
        for excluded in ["authorizationFingerprint", "activeAttempt", "nextFireAt", "bookmark", "secretReference", "environment"] { #expect(command[excluded] == nil) }
        let schedule = try #require(((root["schedules"] as? [String: Any])?["definitions"] as? [[String: Any]])?.first)
        #expect(Set(schedule.keys) == ["id", "name", "workflowID", "enabled", "revision", "trigger"])
        #expect((schedule["trigger"] as? [String: Any])?["kind"] as? String == "daily")
        #expect((root["excludedFields"] as? [String])?.count == 8)
    }
    @Test func AIShortcutsBelongToShortcutsAndPartialDependenciesAreExplicit() throws {
        let source = try ConfigurationExportFixture.source()
        let shortcuts = try ConfigurationExportProjection.make(source: source, sections: [.shortcuts])
        let root = try ConfigurationExportFixture.object(shortcuts)
        let map = try #require((root["shortcuts"] as? [String: Any])?["aiActionShortcuts"] as? [String: Any])
        #expect(map["ai.22222222-2222-4222-8222-222222222222"] != nil && root["definitions"] == nil)
        #expect(shortcuts.unselectedDependencyCount == 3)
        let definitions = try ConfigurationExportProjection.make(source: source, sections: [.definitions])
        let object = try ConfigurationExportFixture.object(definitions)
        let action = try #require((((object["definitions"] as? [String: Any])?["aiActions"]) as? [[String: Any]])?.first)
        #expect(action["shortcut"] == nil && object["shortcuts"] == nil)
        let dependencies = try #require(object["unselectedDependencies"] as? [[String: Any]])
        #expect(dependencies.contains { $0["target"] as? String == "ai-service.global" && $0["requiredSection"] as? String == "resources" })
        #expect(dependencies.contains { $0["target"] as? String == "mcp-server.33333333-3333-4333-8333-333333333333" })
    }
    @Test func disabledMCPAndUnconfiguredAIAndNonexistentStdioResourcesDoNotRequireReadiness() throws {
        var c = AppConfiguration(); c.agents = []
        c.mcpServers = [.init(name: "Missing executable", stdio: .init(executable: "/synthetic/does-not-exist", workingDirectory: "/synthetic/absent"))]
        let frozen = try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.resources])
        #expect(frozen.preview.contains("/synthetic/does-not-exist".replacingOccurrences(of: "/", with: "\\/")) || frozen.preview.contains("/synthetic/does-not-exist"))
        let root = try ConfigurationExportFixture.object(frozen)
        let required = try #require(root["requiredLocalFields"] as? [[String: Any]])
        #expect(required.contains { $0["reference"] as? String == "endpoint" })
        #expect(required.contains { $0["reference"] as? String == "model" })
    }
    @Test func brokenOrTemporaryReferencesDuplicateIDsAndUnknownSchemasFail() throws {
        var c = AppConfiguration(); c.agents = []; c.preferences.favorites = ["window.synthetic-pid"]
        #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.shortcuts]) }
        c.preferences.favorites = ["command." + UUID().uuidString]
        #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.shortcuts]) }
        c.preferences.favorites = []; let command = SavedCommand(name: "Synthetic", executable: "/synthetic/missing")
        c.savedCommands = [command, command]
        #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.definitions]) }
        c.savedCommands = []; c.schemaVersion = 5
        #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.preferences]) }
    }
    @Test func invalidWorkflowCLIBindingsAndEndpointStructuresFail() throws {
        for mode in 0...1 {
            var c = AppConfiguration(); c.agents = []
            var command = SavedCommand(name: "Synthetic", executable: "/synthetic/missing", arguments: ["{{input}}"])
            command.interactive = mode == 0; command.shellMode = mode == 1; c.savedCommands = [command]
            c.workflows = [.init(name: "Synthetic", steps: [.init(operation: .savedCommand(command.id))])]
            #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.definitions]) }
        }
        for endpoint in ["file:///synthetic/local", "https://user:SECRET@example.com", "http://example.com/api"] {
            var c = AppConfiguration(); c.endpoint = endpoint; c.model = "synthetic"
            #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.resources]) }
        }
        let server = MCPServerConfiguration(name: "Synthetic", stdio: .init(executable: "/synthetic/missing", workingDirectory: "/synthetic"))
        for mutation in ["endpoint", "secretReference", "allowsLocalHTTP"] {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(server)) as? [String: Any])
            if mutation == "endpoint" { json[mutation] = "file:///synthetic/other" }
            else if mutation == "secretReference" { json[mutation] = "SECRET" }
            else { json[mutation] = true }
            var c = AppConfiguration(); c.mcpServers = [try JSONDecoder().decode(MCPServerConfiguration.self, from: JSONSerialization.data(withJSONObject: json))]
            #expect(throws: ConfigurationExportError.self) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.resources]) }
        }
    }
    @Test func budgetsCheckActualEncodingCountsAndBytesWithoutTruncation() throws {
        let source = try ConfigurationExportFixture.source()
        let normal = try ConfigurationExportProjection.make(source: source, sections: all)
        #expect(throws: ConfigurationExportError.tooLarge) { try ConfigurationExportProjection.make(source: source, sections: all, maximumBytes: normal.data.count - 1) }
        var c = AppConfiguration(); c.agents = []
        c.savedCommands = (0..<1025).map { SavedCommand(name: "S\($0)", executable: "/synthetic/missing") }
        #expect(throws: ConfigurationExportError.tooLarge) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.definitions]) }
        c.savedCommands = (0..<1000).map { SavedCommand(name: "S\($0)", executable: "/synthetic/missing", environment: ["A": "secret", "B": "secret"]) }
        c.preferences.favorites = Set(c.savedCommands.prefix(100).map { "command." + $0.id.uuidString })
        #expect(throws: ConfigurationExportError.tooLarge) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.definitions, .shortcuts]) }
        c.savedCommands = []; c.preferences.favorites = []
        c.aiActions = (0..<9).map { AIActionPreset(name: "S\($0)", prompt: String(repeating: "x", count: 1_048_576)) }
        #expect(throws: ConfigurationExportError.tooLarge) { try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.definitions]) }
    }
    @Test func validLargePromptAnd129CLIArgumentsArePreserved() throws {
        var c = AppConfiguration(); c.agents = []
        c.aiActions = [.init(name: "Synthetic", prompt: String(repeating: "译", count: 12_000))]
        c.savedCommands = [.init(name: "Synthetic", executable: "/synthetic/missing", arguments: (0..<129).map(String.init))]
        let frozen = try ConfigurationExportProjection.make(source: ConfigurationExportFixture.source(c), sections: [.definitions])
        #expect(frozen.definitionCount == 2)
    }
    @Test func unavailableDesktopNeverMasqueradesAsAnEmptyDefinitionList() throws {
        let source = try ConfigurationExportFixture.source(available: false)
        #expect(throws: ConfigurationExportError.unavailableSource("desktop")) { try ConfigurationExportProjection.make(source: source, sections: [.desktop]) }
        #expect(try ConfigurationExportProjection.make(source: source, sections: [.preferences]).definitionCount == 0)
    }
}
