import Foundation
import Testing
import ExecutionCore

@Suite("动作授权身份")
struct ActionGrantTests {
    private func request(actionID: String = "test.action.run", actionVersion: Int = 2) -> ExecutionRequest {
        ExecutionRequest(commandID: "test.command.ai", commandVersion: 1,
            toolID: "test.tool.network", toolVersion: 1, caller: .user, callerInstanceID: "synthetic.ui",
            resourceScope: .exact(namespace: "test.resource", identifier: "synthetic-A"), effects: [.network],
            actionID: actionID, actionVersion: actionVersion)
    }
    private func grant(for request: ExecutionRequest, actionID: String, actionVersion: Int) -> PolicyGrant {
        PolicyGrant(caller: request.caller, callerInstanceID: request.callerInstanceID,
            commandID: request.commandID, commandVersion: request.commandVersion,
            toolID: request.toolID, toolVersion: request.toolVersion, resourceScope: request.resourceScope,
            allowedEffects: request.effects, expiresAt: .distantFuture, sideEffectsApproved: true,
            actionID: actionID, actionVersion: actionVersion)
    }
    @Test("命令和工具相同也不能借用另一个动作或旧动作版本的授权")
    func actionIdentityAndVersionBound() {
        let r = request()
        #expect(throws: ExecutionPolicyError.actionMismatch) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, actionID: "test.action.other", actionVersion: 2))
        }
        #expect(throws: ExecutionPolicyError.actionVersionMismatch) {
            try ExecutionPolicy.authorize(request: r, grant: grant(for: r, actionID: r.actionID, actionVersion: 1))
        }
    }
    @Test("非法动作身份或版本默认拒绝")
    func malformedActionRejected() {
        for r in [request(actionID: "invalid"), request(actionVersion: 0)] {
            #expect(throws: ExecutionPolicyError.invalidRequest) {
                try ExecutionPolicy.authorize(request: r, grant: nil)
            }
        }
    }
}
