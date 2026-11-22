import Foundation
import Testing
import ExecutionCore

@Suite("调用者和资源授权")
struct ExecutionPolicyTests {
    private func request(
        id: UUID = UUID(), caller: ExecutionCaller = .user, principal: String = "ui.primary",
        commandVersion: Int = 1, toolVersion: Int = 1,
        scope: ExecutionResourceScope = .exact(namespace: "keydock.saved-command", identifier: "configuration-fingerprint-A"),
        effects: Set<ExecutionEffect> = [.executeProcess]
    ) -> ExecutionRequest {
        ExecutionRequest(invocationID: id, commandID: "keydock.command.saved", commandVersion: commandVersion,
                         toolID: "keydock.process.execute", toolVersion: toolVersion, caller: caller,
                         callerInstanceID: principal, resourceScope: scope, effects: effects)
    }
    private func grant(
        for r: ExecutionRequest, caller: ExecutionCaller? = nil, principal: String? = nil,
        commandVersion: Int? = nil, toolVersion: Int? = nil, scope: ExecutionResourceScope? = nil,
        effects: Set<ExecutionEffect>? = nil, expiry: Date = .distantFuture,
        approved: Bool = false, invocation: UUID? = nil
    ) -> PolicyGrant {
        PolicyGrant(caller: caller ?? r.caller, callerInstanceID: principal ?? r.callerInstanceID,
                    commandID: r.commandID, commandVersion: commandVersion ?? r.commandVersion,
                    toolID: r.toolID, toolVersion: toolVersion ?? r.toolVersion,
                    resourceScope: scope ?? r.resourceScope, allowedEffects: effects ?? r.effects,
                    expiresAt: expiry, sideEffectsApproved: approved, invocationID: invocation)
    }

    @Test("缺少授权和空效果默认拒绝")
    func failClosed() {
        let r = request()
        #expect(throws: ExecutionPolicyError.missingGrant) { try ExecutionPolicy.authorize(request: r, grant: nil) }
        let empty = request(effects: [])
        #expect(throws: ExecutionPolicyError.invalidRequest) { try ExecutionPolicy.authorize(request: empty, grant: nil) }
        let unscoped = request(scope: .none)
        #expect(throws: ExecutionPolicyError.invalidRequest) { try ExecutionPolicy.authorize(request: unscoped, grant: nil) }
    }

    @Test("调用入口和具体运行身份都必须匹配")
    func callerBound() {
        let r = request()
        #expect(throws: ExecutionPolicyError.callerMismatch) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, caller: .shortcut, approved: true))
        }
        #expect(throws: ExecutionPolicyError.callerMismatch) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, principal: "ui.other", approved: true))
        }
    }

    @Test("命令和工具版本分别绑定")
    func versionsBound() {
        let r = request(commandVersion: 2, toolVersion: 3)
        #expect(throws: ExecutionPolicyError.commandVersionMismatch) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, commandVersion: 1, approved: true))
        }
        #expect(throws: ExecutionPolicyError.toolVersionMismatch) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, toolVersion: 2, approved: true))
        }
    }

    @Test("范围精确匹配，不把相似前缀视为相同目录")
    func exactScopeOnly() {
        let r = request(scope: .exact(namespace: "keydock.directory", identifier: "/tmp/project-other"))
        let g = grant(for: r, scope: .exact(namespace: "keydock.directory", identifier: "/tmp/project"), approved: true)
        #expect(throws: ExecutionPolicyError.resourceMismatch) { try ExecutionPolicy.authorize(request: r, grant: g) }
    }

    @Test("过期或不同 invocation 的授权不可使用")
    func expiryAndInvocationBound() {
        let r = request()
        #expect(throws: ExecutionPolicyError.expiredGrant) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, expiry: .distantPast, approved: true))
        }
        #expect(throws: ExecutionPolicyError.invocationMismatch) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, approved: true, invocation: UUID()))
        }
    }

    @Test("副作用必须有宿主明确批准，已批准配置可复用")
    func sideEffectsRequireApproval() throws {
        let r = request()
        #expect(throws: ExecutionPolicyError.sideEffectApprovalRequired) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r))
        }
        try ExecutionPolicy.authorize(request: r, grant: grant(for: r, approved: true))
    }

    @Test("Agent 只读可用，误配写授权也不能扩大第一阶段范围")
    func agentReadOnlyBoundary() throws {
        let read = request(caller: .agent, principal: "agent.run-1", scope: .none, effects: [.read])
        try ExecutionPolicy.authorize(request: read, grant: grant(for: read))
        let write = request(caller: .agent, principal: "agent.run-1")
        #expect(throws: ExecutionPolicyError.agentWriteUnsupported) {
            try ExecutionPolicy.authorize(request: write, grant: grant(for: write, approved: true))
        }
    }

    @Test("声明外的效果不可执行")
    func effectsCannotEscalate() {
        let r = request(effects: [.read, .executeProcess])
        #expect(throws: ExecutionPolicyError.effectNotPermitted) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, effects: [.read], approved: true))
        }
    }
}
