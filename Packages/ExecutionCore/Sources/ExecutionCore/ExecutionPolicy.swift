import Foundation

public enum ExecutionCaller: String, Hashable, Sendable {
    case user, shortcut, agent, workflow
}

/// 独立于 UI 命令模型，由宿主从已注册能力映射，不能采信模型自报效果。
public enum ExecutionEffect: String, Hashable, Sendable, CaseIterable {
    case read, activateApplication, activateWindow, executeProcess, replaceText
    case writeClipboard, writeFile, network, publish
    public var isReadOnly: Bool { self == .read }
}

/// 只做精确匹配，不提供路径前缀、通配符或隐式整机范围。
public enum ExecutionResourceScope: Hashable, Sendable {
    case none
    case exact(namespace: String, identifier: String)
}

/// 不实现 Decodable；caller、版本、范围和效果必须由宿主从真实调用入口构造。
public struct ExecutionRequest: Sendable {
    public let invocationID: UUID
    public let commandID: String
    public let commandVersion: Int
    public let actionID: String
    public let actionVersion: Int
    public let toolID: String
    public let toolVersion: Int
    public let caller: ExecutionCaller
    public let callerInstanceID: String
    public let resourceScope: ExecutionResourceScope
    public let effects: Set<ExecutionEffect>

    public init(
        invocationID: UUID = UUID(), commandID: String, commandVersion: Int,
        toolID: String, toolVersion: Int, caller: ExecutionCaller, callerInstanceID: String,
        resourceScope: ExecutionResourceScope, effects: Set<ExecutionEffect> = [],
        actionID: String? = nil, actionVersion: Int? = nil
    ) {
        self.invocationID = invocationID; self.commandID = commandID; self.commandVersion = commandVersion
        self.actionID = actionID ?? commandID; self.actionVersion = actionVersion ?? commandVersion
        self.toolID = toolID; self.toolVersion = toolVersion; self.caller = caller
        self.callerInstanceID = callerInstanceID; self.resourceScope = resourceScope; self.effects = effects
    }
}

/// 仅由可信宿主创建，不可从模型 JSON、网页、工具 annotations 或扩展清单解码。
/// 这不是对不可信同进程代码的安全沙箱；持有宿主代码执行权的代码仍需真实隔离。
public struct PolicyGrant: Sendable {
    public let id: UUID
    public let caller: ExecutionCaller
    public let callerInstanceID: String
    public let commandID: String
    public let commandVersion: Int
    public let actionID: String
    public let actionVersion: Int
    public let toolID: String
    public let toolVersion: Int
    public let resourceScope: ExecutionResourceScope
    public let allowedEffects: Set<ExecutionEffect>
    public let expiresAt: Date
    public let sideEffectsApproved: Bool
    /// 仅限真实用户逐次批准的Agent调用；P1只读路径从不设置，且必须绑定invocationID。
    public let agentInvocationApproved: Bool
    /// nil 用于已保存的可重复动作；非 nil 只匹配指定调用身份。消费/防重放仍由 invocation 回执层管理。
    public let invocationID: UUID?

    public init(
        id: UUID = UUID(), caller: ExecutionCaller, callerInstanceID: String,
        commandID: String, commandVersion: Int, toolID: String, toolVersion: Int,
        resourceScope: ExecutionResourceScope, allowedEffects: Set<ExecutionEffect> = [],
        expiresAt: Date, sideEffectsApproved: Bool = false, invocationID: UUID? = nil,
        actionID: String? = nil, actionVersion: Int? = nil, agentInvocationApproved: Bool = false
    ) {
        self.id = id; self.caller = caller; self.callerInstanceID = callerInstanceID
        self.commandID = commandID; self.commandVersion = commandVersion
        self.actionID = actionID ?? commandID; self.actionVersion = actionVersion ?? commandVersion
        self.toolID = toolID; self.toolVersion = toolVersion; self.resourceScope = resourceScope
        self.allowedEffects = allowedEffects; self.expiresAt = expiresAt
        self.agentInvocationApproved = agentInvocationApproved
        self.sideEffectsApproved = sideEffectsApproved; self.invocationID = invocationID
    }
}

public enum ExecutionPolicyError: Error, Equatable, Sendable {
    case missingGrant, invalidRequest, invalidGrant, expiredGrant, callerMismatch
    case commandMismatch, commandVersionMismatch, actionMismatch, actionVersionMismatch, toolMismatch, toolVersionMismatch
    case resourceMismatch, effectNotPermitted, sideEffectApprovalRequired, invocationMismatch
    case agentWriteUnsupported
}

public enum ExecutionPolicy {
    public static func authorize(request: ExecutionRequest, grant: PolicyGrant?) throws {
        guard validID(request.commandID), validID(request.actionID), validID(request.toolID),
              request.commandVersion > 0, request.actionVersion > 0,
              request.toolVersion > 0, validPrincipal(request.callerInstanceID),
              !request.effects.isEmpty, validScope(request.resourceScope, effects: request.effects) else {
            throw ExecutionPolicyError.invalidRequest
        }
        guard let grant else { throw ExecutionPolicyError.missingGrant }
        guard validID(grant.commandID), validID(grant.actionID), validID(grant.toolID),
              grant.commandVersion > 0, grant.actionVersion > 0,
              grant.toolVersion > 0, validPrincipal(grant.callerInstanceID), !grant.allowedEffects.isEmpty,
              grant.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              validScope(grant.resourceScope, effects: grant.allowedEffects) else {
            throw ExecutionPolicyError.invalidGrant
        }
        guard grant.expiresAt > Date() else { throw ExecutionPolicyError.expiredGrant }
        guard request.caller == grant.caller, request.callerInstanceID == grant.callerInstanceID else {
            throw ExecutionPolicyError.callerMismatch
        }
        guard request.commandID == grant.commandID else { throw ExecutionPolicyError.commandMismatch }
        guard request.commandVersion == grant.commandVersion else { throw ExecutionPolicyError.commandVersionMismatch }
        guard request.actionID == grant.actionID else { throw ExecutionPolicyError.actionMismatch }
        guard request.actionVersion == grant.actionVersion else { throw ExecutionPolicyError.actionVersionMismatch }
        guard request.toolID == grant.toolID else { throw ExecutionPolicyError.toolMismatch }
        guard request.toolVersion == grant.toolVersion else { throw ExecutionPolicyError.toolVersionMismatch }
        guard request.resourceScope == grant.resourceScope else { throw ExecutionPolicyError.resourceMismatch }
        guard request.effects.isSubset(of: grant.allowedEffects) else { throw ExecutionPolicyError.effectNotPermitted }
        if let invocationID = grant.invocationID, request.invocationID != invocationID {
            throw ExecutionPolicyError.invocationMismatch
        }
        let hasSideEffect = request.effects.contains { !$0.isReadOnly }
        // P1默认保持只读；P2授权必须精确绑定本次调用，不能把一次确认变为长期grant。
        guard request.caller != .agent || !hasSideEffect || (grant.agentInvocationApproved && grant.invocationID == request.invocationID) else { throw ExecutionPolicyError.agentWriteUnsupported }
        guard !hasSideEffect || grant.sideEffectsApproved else { throw ExecutionPolicyError.sideEffectApprovalRequired }
    }

    private static func validScope(_ scope: ExecutionResourceScope, effects: Set<ExecutionEffect>) -> Bool {
        switch scope {
        case .none:
            effects.allSatisfy(\.isReadOnly)
        case let .exact(namespace, identifier):
            validID(namespace) && !identifier.isEmpty
        }
    }
    private static func validPrincipal(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return id.utf8.count <= 512 && parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
            }
        }
    }
}
