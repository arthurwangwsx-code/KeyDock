import Foundation
import Testing
import ExecutionCore
import AgentCore
import AutomationCore
import MacAdapters
@testable import WorkbenchFeature

@Suite struct RunDefinitionFingerprintTests {
    @Test func v1GoldenVectorsKeepThePersistedFingerprintContractStable() throws {
        func id(_ suffix: String) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-00000000000" + suffix)! }
        let command = SavedCommand(id: id("1"), name: "Synthetic CLI", executable: "/usr/bin/printf", arguments: ["%s", "text"], workingDirectory: "/tmp", environment: ["Z": "last", "A": "first"])
        var action = AIActionPreset(name: "Synthetic AI", prompt: "translate"); action.id = id("2"); action.input = .manual
        var agent = AgentDefinition(); agent.id = id("3"); agent.version = 2; agent.name = "Synthetic Agent"; agent.instructions = "Follow current scope."
        agent.allowedCommandIDs = [id("1")]; agent.allowedMCPServerIDs = [id("6")]; agent.allowedMCPToolNames = ["tool_b", "tool_a"]
        agent.maxToolCalls = 3; agent.maxTurns = 2; agent.timeoutSeconds = 30
        let workflow = WorkflowDefinition(id: id("4"), name: "Synthetic Workflow", steps: [.init(id: id("5"), operation: .transform(.trim), input: .literal(" text "))])
        // 由独立Python sorted JSON/SHA-256计算；不在测试中调用待测编码器重算期望值。
        #expect(try RunDefinitionFingerprint.reference(command).fingerprint == "4a9924aefa831e7965b980b467b6afe7ba0d8fa3c0c9d189c6537271136b894f")
        #expect(try RunDefinitionFingerprint.reference(action).fingerprint == "7b133bc0f9755a1a5b32bd17d9253b1a462ab7ef24fada3f50032e34d2d43dc5")
        #expect(try RunDefinitionFingerprint.reference(agent).fingerprint == "6b66e94ad35b2132e26157ffbe6bee48175ec01bfcbd17b1bd1f43a036cf2d77")
        #expect(try RunDefinitionFingerprint.reference(workflow).fingerprint == "40b7244ea0b2bcae29ecf2acf855d4bf55b8c46cd8e427c6f07c58d83b0e1bd1")
    }
    @Test func commandCoversEveryFieldAndPreservesArgumentOrder() throws {
        let value = SavedCommand(name: "Synthetic command", executable: "/usr/bin/printf", arguments: ["%s", "text"], workingDirectory: "/tmp", environment: ["Z": "last", "A": "first"])
        let baseline = try RunDefinitionFingerprint.reference(value)
        #expect(baseline.kind == .savedCommand && baseline.definitionID == value.id && baseline.definitionVersion == nil && baseline.isValid)
        var reordered = value; reordered.environment = [:]
        reordered.environment["A"] = "first"; reordered.environment["Z"] = "last"
        #expect(try RunDefinitionFingerprint.reference(reordered) == baseline)
        let changes: [(inout SavedCommand) -> Void] = [
            { $0.id = UUID() }, { $0.name += " " }, { $0.executable += "x" }, { $0.arguments.reverse() },
            { $0.arguments.append("") }, { $0.workingDirectory += "/" }, { $0.environment["A"] = "changed" },
            { $0.environment["NEW"] = "" }, { $0.timeout = $0.timeout.nextUp }, { $0.interactive.toggle() }, { $0.shellMode.toggle() }
        ]
        for change in changes { var changed = value; change(&changed); #expect(try RunDefinitionFingerprint.reference(changed).fingerprint != baseline.fingerprint) }
    }
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, 0, -1, 86_401])
    func invalidTimeoutIsNotHashedAsAnAcceptableDefinition(_ timeout: Double) {
        var value = SavedCommand(name: "Synthetic invalid", executable: "/usr/bin/printf", workingDirectory: "/tmp"); value.timeout = timeout
        #expect(throws: SavedCommandValidationError.invalidTimeout) { try RunDefinitionFingerprint.reference(value) }
    }
    @Test func actionIncludesNilEmptyAndDeliveryAndShortcutFields() throws {
        var value = AIActionPreset(name: "Synthetic action", prompt: "Translate exactly"); value.input = .manual
        let baseline = try RunDefinitionFingerprint.reference(value)
        #expect(baseline.kind == .aiAction && baseline.definitionVersion == nil)
        let changes: [(inout AIActionPreset) -> Void] = [
            { $0.id = UUID() }, { $0.name += " " }, { $0.builtinKey = "" }, { $0.prompt += " " },
            { $0.input = .clipboard }, { $0.output = .copy }, { $0.modelOverride = "model" }, { $0.shortcut = .init() }
        ]
        for change in changes { var changed = value; change(&changed); #expect(try RunDefinitionFingerprint.reference(changed).fingerprint != baseline.fingerprint) }
        value.shortcut = .init(keyCode: 12, modifiers: 0x1800)
        let shortcut = try RunDefinitionFingerprint.reference(value)
        var key = value; key.shortcut?.keyCode = 13
        var modifiers = value; modifiers.shortcut?.modifiers = 0x1000
        #expect(try RunDefinitionFingerprint.reference(key) != shortcut && RunDefinitionFingerprint.reference(modifiers) != shortcut)
    }
    @Test func agentSetsAreDeterministicAndAllDefinitionFieldsAreCovered() throws {
        let ids = [UUID(), UUID(), UUID()]
        var value = AgentDefinition(); value.name = "Synthetic agent"
        value.allowedCommandIDs = Set(ids); value.allowedMCPServerIDs = Set(ids)
        value.allowedMCPToolNames = ["tool_z", "tool_a", "tool_2"]
        let baseline = try RunDefinitionFingerprint.reference(value)
        #expect(baseline.kind == .agent && baseline.definitionVersion == value.version)
        var reordered = value; reordered.allowedCommandIDs = []; reordered.allowedMCPServerIDs = []; reordered.allowedMCPToolNames = []
        for id in ids.reversed() { reordered.allowedCommandIDs.insert(id); reordered.allowedMCPServerIDs.insert(id) }
        for name in ["tool_2", "tool_a", "tool_z"] { reordered.allowedMCPToolNames.insert(name) }
        #expect(try RunDefinitionFingerprint.reference(reordered) == baseline)
        #expect(try RunDefinitionFingerprint.reference(JSONDecoder().decode(AgentDefinition.self, from: JSONEncoder().encode(value))) == baseline)
        let changes: [(inout AgentDefinition) -> Void] = [
            { $0.id = UUID() }, { $0.version += 1 }, { $0.name += " " }, { $0.instructions += " " }, { $0.modelOverride = "model" },
            { $0.allowedCommandIDs.remove(ids[0]) }, { $0.allowedMCPServerIDs.remove(ids[0]) }, { $0.allowedMCPToolNames.remove("tool_a") },
            { $0.maxToolCalls += 1 }, { $0.maxTurns += 1 }, { $0.timeoutSeconds += 1 }, { $0.maxRunTokens = 100 }
        ]
        for change in changes { var changed = value; change(&changed); #expect(try RunDefinitionFingerprint.reference(changed).fingerprint != baseline.fingerprint) }
        var invalid = value; invalid.version = 0
        #expect(throws: InvocationStoreError.invalidMetadata) { try RunDefinitionFingerprint.reference(invalid) }
    }
    @Test func workflowPreservesStepIdentityOrderOperationAndInputTags() throws {
        let target = UUID()
        let value = WorkflowDefinition(name: "Synthetic workflow", steps: [.init(operation: .savedCommand(target), input: .literal("")), .init(operation: .transform(.trim), input: .previousOutput)])
        let baseline = try RunDefinitionFingerprint.reference(value)
        #expect(baseline.kind == .workflow && baseline.definitionVersion == value.version)
        let changes: [(inout WorkflowDefinition) -> Void] = [
            { $0.id = UUID() }, { $0.name += " " }, { $0.version += 1 }, { $0.steps.reverse() }, { $0.steps[0].id = UUID() },
            { $0.steps[0].operation = .savedCommand(UUID()) }, { $0.steps[0].operation = .aiAction(target) },
            { $0.steps[0].operation = .manualInput }, { $0.steps[1].operation = .transform(.uppercase) },
            { $0.steps[0].input = .workflowInput }, { $0.steps[0].input = .literal(" ") }, { $0.steps[1].input = .workflowInput }
        ]
        for change in changes { var changed = value; change(&changed); #expect(try RunDefinitionFingerprint.reference(changed).fingerprint != baseline.fingerprint) }
        var invalid = value; invalid.version = 0
        #expect(throws: InvocationStoreError.invalidMetadata) { try RunDefinitionFingerprint.reference(invalid) }
    }
    @Test func canonicallyEquivalentUnicodeStillChangesTheByteIdentity() throws {
        let nfc = "Caf\u{e9}", nfd = "Cafe\u{301}"
        #expect(nfc == nfd && Data(nfc.utf8) != Data(nfd.utf8))
        var command = SavedCommand(name: nfc, executable: "/usr/bin/printf", workingDirectory: "/tmp"), changedCommand = command
        changedCommand.name = nfd
        #expect(try RunDefinitionFingerprint.reference(command) != RunDefinitionFingerprint.reference(changedCommand))
        command.environment = [nfc: nfc]; changedCommand = command; changedCommand.environment = [nfd: nfd]
        #expect(try RunDefinitionFingerprint.reference(command) != RunDefinitionFingerprint.reference(changedCommand))
        var action = AIActionPreset(name: "Synthetic", prompt: nfc), changedAction = action; changedAction.prompt = nfd
        #expect(try RunDefinitionFingerprint.reference(action) != RunDefinitionFingerprint.reference(changedAction))
        action.modelOverride = nfc; changedAction = action; changedAction.modelOverride = nfd
        #expect(try RunDefinitionFingerprint.reference(action) != RunDefinitionFingerprint.reference(changedAction))
        var agent = AgentDefinition(); agent.instructions = nfc; var changedAgent = agent; changedAgent.instructions = nfd
        #expect(try RunDefinitionFingerprint.reference(agent) != RunDefinitionFingerprint.reference(changedAgent))
        let workflow = WorkflowDefinition(name: "Synthetic", steps: [.init(operation: .transform(.trim), input: .literal(nfc))])
        var changedWorkflow = workflow; changedWorkflow.steps[0].input = .literal(nfd)
        #expect(try RunDefinitionFingerprint.reference(workflow) != RunDefinitionFingerprint.reference(changedWorkflow))
    }
    @Test func resolutionUsesOnlyTheExactTypedSavedIdentity() throws {
        let command = SavedCommand(name: "Same title", executable: "/usr/bin/printf", workingDirectory: "/tmp")
        var action = AIActionPreset(name: command.name, prompt: "Synthetic"); action.id = command.id
        var configuration = AppConfiguration(); configuration.savedCommands = [command]; configuration.aiActions = [action]
        let reference = try RunDefinitionFingerprint.reference(command)
        #expect(try SavedRunDefinition.resolve(reference, in: configuration)?.reference == reference)
        configuration.savedCommands[0].name = "Current edited title"
        #expect(try SavedRunDefinition.resolve(reference, in: configuration)?.reference != reference)
        configuration.savedCommands = []
        #expect(SavedRunDefinition.resolve(reference, in: configuration) == nil)
        configuration.savedCommands = [command, command]
        #expect(SavedRunDefinition.resolve(reference, in: configuration) == nil)
        configuration.savedCommands = [command]
        configuration.language = "zh-Hans"; configuration.endpoint = "https://synthetic.invalid/v1"; configuration.model = "other"; configuration.disabledContributions = ["keydock.command"]
        #expect(try SavedRunDefinition.resolve(reference, in: configuration)?.reference == reference)
    }
}
