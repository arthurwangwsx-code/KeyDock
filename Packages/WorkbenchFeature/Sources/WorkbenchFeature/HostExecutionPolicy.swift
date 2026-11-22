import Foundation
import CryptoKit
import CommandCore
import ExecutionCore
import AICore

/// 真实 UI/已保存快捷键的宿主决策边界；模型只能产生草稿或工具参数，不能提供 grant。
extension WorkbenchModel {
    func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func fingerprint(_ command: SavedCommand) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(command)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult func authorizeHostAction(
        id: String, operation: HostOperation, resource: String,
        availableContext: Set<CommandContextRequirement> = [], modelOverride: String = "",
        caller: ExecutionCaller = .user, invocation: UUID = UUID()
    ) throws -> ExecutionRequest {
        guard !isShuttingDown else { throw WorkbenchLifecycleError.shuttingDown }
        let descriptor = try hostDescriptor(id: id, title: "KeyDock", operations: [operation], modelOverride: modelOverride)
        let scope = ExecutionResourceScope.exact(namespace: "keydock.resource", identifier: fingerprint(resource))
        let source = caller == .shortcut ? "shortcut." + fingerprint(id) : "interactive-ui"
        // 此处仅由真实用户入口创建授权，不采信模型 self-report 的批准或风险字段。
        return try HostDescriptorPolicy.authorize(
            descriptor: descriptor, availableContext: availableContext, resourceScope: scope,
            caller: caller, callerInstanceID: source, invocationID: invocation, sideEffectsApproved: true)
    }

    func descriptor(for item: CommandItem) throws -> CommandDescriptor {
        let operation = HostActionCatalog.operation(for: item.kind)
        // AI 默认动作只打开输入界面；执行动作另声明并使用相同目录定义。
        let operations: [HostOperation] = item.kind == .ai ? [.prepareAI, .generateText] : [operation]
        let override = configuration.aiActions.first { "ai." + $0.id.uuidString == item.id }?.modelOverride ?? ""
        return try hostDescriptor(id: item.id, title: item.title, keywords: item.keywords, operations: operations, modelOverride: override)
    }

    /// 使用同一个实际目录描述执行；不会先检查一个描述，再重建另一套 effect/version。
    @discardableResult func authorizeHostItem(_ item: CommandItem, caller: ExecutionCaller) throws -> ExecutionRequest {
        guard !isShuttingDown else { throw WorkbenchLifecycleError.shuttingDown }
        let context: Set<CommandContextRequirement> = item.kind == .window ? [.window] : []
        return try HostDescriptorPolicy.authorize(
            descriptor: descriptor(for: item), availableContext: context,
            resourceScope: .exact(namespace: "keydock.resource", identifier: fingerprint(item.payload + (item.objectRevision.map { "|" + $0 } ?? ""))),
            caller: caller, callerInstanceID: caller == .shortcut ? "shortcut." + fingerprint(item.id) : "interactive-ui",
            sideEffectsApproved: true)
    }

    private func hostDescriptor(
        id: String, title: String, keywords: [String] = [], operations: [HostOperation], modelOverride: String = ""
    ) throws -> CommandDescriptor {
        var availability: [HostOperation: CommandAvailability] = [:]
        for operation in operations { availability[operation] = hostAvailability(for: operation, modelOverride: modelOverride) }
        return try HostActionCatalog.descriptor(
            id: "keydock.command." + fingerprint(id), title: title, keywords: keywords,
            operations: operations, actionAvailability: availability)
    }

    private func hostAvailability(for operation: HostOperation, modelOverride: String) -> CommandAvailability {
        switch operation {
        case .activateWindow, .replaceSelection:
            return desktop.accessibilityGranted ? .available : .unavailable(reasonKey: "Accessibility permission is required")
        case .generateText, .proposeCommand, .runReadOnlyAgent:
            guard let endpoint = URL(string: configuration.endpoint), !configuration.endpoint.isEmpty else {
                return .unavailable(reasonKey: "Configure a valid API endpoint and model in Settings")
            }
            let config = AIProviderConfiguration(endpoint: endpoint,
                model: modelOverride.isEmpty ? configuration.model : modelOverride,
                allowsLocalHTTP: configuration.localHTTP,
                tokenLimitParameter: TokenLimitParameter(rawValue: configuration.tokenLimitParameter) ?? .maxCompletionTokens)
            do { try config.validate(); return .available }
            catch { return .unavailable(reasonKey: "Configure a valid API endpoint and model in Settings") }
        default: return .available
        }
    }
}
