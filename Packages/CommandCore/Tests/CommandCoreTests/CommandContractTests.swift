import Foundation
import Testing
import CommandCore

@Suite("版本化命令合同")
struct CommandContractTests {
    private func action(id: String = "keydock.command.run") throws -> ActionDescriptor {
        try ActionDescriptor(
            id: id, version: 2, title: "Run", inputType: .structuredData, outputType: .text,
            requiredContext: [.workingDirectory], effects: [.executeProcess],
            execution: .init(toolID: "keydock.process.execute", toolVersion: 3)
        )
    }

    @Test("无命名空间或非法版本不能注册")
    func invalidIdentityCannotRegister() throws {
        #expect(throws: CommandContractError.invalidIdentifier) {
            try CommandExecutionReference(toolID: "run", toolVersion: 1)
        }
        #expect(throws: CommandContractError.invalidVersion) {
            try CommandExecutionReference(toolID: "keydock.process.execute", toolVersion: 0)
        }
        #expect(throws: CommandContractError.invalidIdentifier) {
            try action(id: "keydock..run")
        }
    }

    @Test("动作集合必须完整且默认动作明确")
    func ambiguousActionsRejected() throws {
        let a = try action()
        #expect(throws: CommandContractError.missingActions) {
            try CommandDescriptor(id: "keydock.command.saved", version: 1, title: "Saved", providerID: "keydock.user", actions: [])
        }
        #expect(throws: CommandContractError.duplicateActionID) {
            try CommandDescriptor(id: "keydock.command.saved", version: 1, title: "Saved", providerID: "keydock.user", actions: [a, a])
        }
        #expect(throws: CommandContractError.invalidDefaultAction) {
            try CommandDescriptor(id: "keydock.command.saved", version: 1, title: "Saved", providerID: "keydock.user", actions: [a], defaultActionID: "keydock.missing")
        }
    }

    @Test("解码也执行版本校验，不能绕过注册不变量")
    func invalidDecodedManifestRejected() throws {
        let descriptor = try CommandDescriptor(id: "keydock.command.saved", version: 1, title: "Saved", providerID: "keydock.user", actions: [action()])
        let data = try JSONEncoder().encode(descriptor)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 0
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CommandContractError.invalidVersion) {
            try JSONDecoder().decode(CommandDescriptor.self, from: invalid)
        }
        let restored = try JSONDecoder().decode(CommandDescriptor.self, from: data)
        #expect(restored.defaultAction.execution.toolVersion == 3)
        #expect(restored.inputType == .structuredData)
        #expect(restored.outputType == .text)
    }
}
