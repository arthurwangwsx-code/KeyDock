import Foundation
import CommandCore
import ExecutionCore

enum HostDescriptorPolicyError: Error, Equatable, Sendable {
    case unavailable(reasonKey: String)
    case unknownAction
    case missingContext(Set<CommandContextRequirement>)
    case unsupportedEffect
}

/// 将已注册声明投影为请求，不能接受调用者另报 effect、tool 或版本。
/// availableContext 与 sideEffectsApproved 仅来自宿主校验或真实用户触发，不能由模型解码。
enum HostDescriptorPolicy {
    @discardableResult static func authorize(
        descriptor: CommandDescriptor, actionID: String? = nil,
        availableContext: Set<CommandContextRequirement> = [],
        resourceScope: ExecutionResourceScope, caller: ExecutionCaller,
        callerInstanceID: String, invocationID: UUID = UUID(),
        sideEffectsApproved: Bool = false
    ) throws -> ExecutionRequest {
        // UI 边界不接受 Agent/workflow 身份；Agent 继续使用既有只读 Broker。
        guard caller == .user || caller == .shortcut else { throw ExecutionPolicyError.callerMismatch }
        try requireAvailable(descriptor.availability)
        let selectedID = actionID ?? descriptor.defaultActionID
        guard let action = descriptor.actions.first(where: { $0.id == selectedID }) else {
            throw HostDescriptorPolicyError.unknownAction
        }
        try requireAvailable(action.availability)
        let missing = action.requiredContext.subtracting(availableContext)
        guard missing.isEmpty else { throw HostDescriptorPolicyError.missingContext(missing) }
        let effects = try Set(action.effects.map { effect in
            guard let mapped = ExecutionEffect(rawValue: effect.rawValue) else {
                throw HostDescriptorPolicyError.unsupportedEffect
            }
            return mapped
        })
        let request = ExecutionRequest(
            invocationID: invocationID, commandID: descriptor.id, commandVersion: descriptor.version,
            toolID: action.execution.toolID, toolVersion: action.execution.toolVersion,
            caller: caller, callerInstanceID: callerInstanceID, resourceScope: resourceScope, effects: effects,
            actionID: action.id, actionVersion: action.version)
        let grant = PolicyGrant(
            caller: caller, callerInstanceID: callerInstanceID,
            commandID: descriptor.id, commandVersion: descriptor.version,
            toolID: action.execution.toolID, toolVersion: action.execution.toolVersion,
            resourceScope: resourceScope, allowedEffects: effects,
            expiresAt: Date().addingTimeInterval(30), sideEffectsApproved: sideEffectsApproved,
            invocationID: invocationID, actionID: action.id, actionVersion: action.version)
        try ExecutionPolicy.authorize(request: request, grant: grant)
        return request
    }

    private static func requireAvailable(_ value: CommandAvailability) throws {
        if case .unavailable(let reasonKey) = value {
            throw HostDescriptorPolicyError.unavailable(reasonKey: reasonKey)
        }
    }
}
