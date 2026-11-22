import Foundation
import CryptoKit
import CommandCore
import ExecutionCore

/// 真实 UI/已保存快捷键的宿主决策边界；模型只能产生草稿或工具参数，不能提供 grant。
extension WorkbenchModel {
    func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func fingerprint(_ command: SavedCommand) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(command)).map { String(format: "%02x", $0) }.joined()
    }
    @discardableResult func authorizeHostAction(id: String, effect: ExecutionEffect, resource: String, caller: ExecutionCaller = .user, invocation: UUID = UUID()) throws -> ExecutionRequest {
        guard caller == .user || caller == .shortcut else { throw ExecutionPolicyError.callerMismatch }
        let commandID = "keydock.command." + fingerprint(id)
        let toolID = "keydock.tool." + effect.rawValue
        let scope = ExecutionResourceScope.exact(namespace: "keydock.resource", identifier: fingerprint(resource))
        let source = caller == .shortcut ? "shortcut." + fingerprint(id) : "interactive-ui"
        let request = ExecutionRequest(invocationID: invocation, commandID: commandID, commandVersion: 1, toolID: toolID, toolVersion: 1, caller: caller, callerInstanceID: source, resourceScope: scope, effects: [effect])
        // 此处只从真实点击或已保存快捷键创建授权，不读取模型自报 risk/approval 字段。
        let grant = PolicyGrant(caller: caller, callerInstanceID: source, commandID: commandID, commandVersion: 1, toolID: toolID, toolVersion: 1, resourceScope: scope, allowedEffects: [effect], expiresAt: Date().addingTimeInterval(30), sideEffectsApproved: true, invocationID: invocation)
        try ExecutionPolicy.authorize(request: request, grant: grant)
        return request
    }
    func descriptor(for item: CommandItem) throws -> CommandDescriptor {
        let effect: CommandEffect
        let input: CommandValueType
        let context: Set<CommandContextRequirement>
        switch item.kind {
        case .application: effect = .activateApplication; input = .application; context = []
        case .window: effect = .activateWindow; input = .window; context = [.window]
        case .command: effect = .executeProcess; input = .structuredData; context = [.workingDirectory]
        case .ai: effect = .network; input = .text; context = [.explicitInput]
        case .clipboard: effect = .read; input = .clipboardItem; context = [.clipboard]
        case .utility: effect = .read; input = .none; context = []
        }
        let reference = try CommandExecutionReference(toolID: "keydock.tool." + effect.rawValue, toolVersion: 1)
        let action = try ActionDescriptor(id: "keydock.action." + item.kind.rawValue, version: 1, title: item.title, inputType: input, outputType: .text, requiredContext: context, effects: [effect], execution: reference)
        return try CommandDescriptor(id: "keydock.command." + fingerprint(item.id), version: 1, title: item.title, providerID: "keydock.provider." + item.kind.rawValue, keywords: item.keywords, actions: [action])
    }
}
