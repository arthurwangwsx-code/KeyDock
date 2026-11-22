import Foundation
import Testing
import CommandCore
import ExecutionCore
@testable import WorkbenchFeature

@Suite("宿主声明驱动执行")
struct HostDescriptorPolicyTests {
    private let scope = ExecutionResourceScope.exact(namespace: "keydock.test", identifier: "synthetic-resource")

    private func command(
        availability: CommandAvailability = .available,
        actionAvailability: CommandAvailability = .available,
        effects: Set<CommandEffect> = [.read], context: Set<CommandContextRequirement> = []
    ) throws -> CommandDescriptor {
        let action = try ActionDescriptor(id: "test.action.selected", version: 7, title: "Synthetic",
            inputType: .text, outputType: .text, availability: actionAvailability, requiredContext: context,
            effects: effects, execution: CommandExecutionReference(toolID: "test.tool.registered", toolVersion: 11))
        return try CommandDescriptor(id: "test.command.registered", version: 5, title: "Synthetic",
            providerID: "test.provider.host", availability: availability, actions: [action])
    }

    @Test("请求真实消费声明的命令/动作/工具版本和效果")
    func declaredMetadataIsConsumed() throws {
        let descriptor = try command(effects: [.read, .network])
        let invocation = UUID()
        let request = try HostDescriptorPolicy.authorize(descriptor: descriptor, resourceScope: scope,
            caller: .shortcut, callerInstanceID: "synthetic.shortcut", invocationID: invocation, sideEffectsApproved: true)
        #expect(request.commandID == descriptor.id && request.commandVersion == 5)
        #expect(request.actionID == descriptor.defaultAction.id && request.actionVersion == 7)
        #expect(request.toolID == "test.tool.registered" && request.toolVersion == 11)
        #expect(request.effects == [.read, .network] && request.invocationID == invocation)
        #expect(request.resourceScope == scope && request.caller == .shortcut)
    }

    @Test("命令或动作不可用均拒绝，不能靠用户授权绕过")
    func availabilityIsEnforced() throws {
        let denied = CommandAvailability.unavailable(reasonKey: "Synthetic unavailable")
        let whole = try command(availability: denied)
        let action = try command(actionAvailability: denied)
        for descriptor in [whole, action] {
            #expect(throws: HostDescriptorPolicyError.unavailable(reasonKey: "Synthetic unavailable")) {
                try HostDescriptorPolicy.authorize(descriptor: descriptor, resourceScope: scope,
                    caller: .user, callerInstanceID: "synthetic.ui", sideEffectsApproved: true)
            }
        }
    }

    @Test("显式输入与选区必须由宿主提供，不能忽略 requiredContext")
    func missingContextFailsClosed() throws {
        let descriptor = try command(context: [.explicitInput, .selection])
        #expect(throws: HostDescriptorPolicyError.missingContext([.selection])) {
            try HostDescriptorPolicy.authorize(descriptor: descriptor, availableContext: [.explicitInput],
                resourceScope: scope, caller: .user, callerInstanceID: "synthetic.ui")
        }
    }

    @Test("未注册动作不可悄悄退回默认动作")
    func unknownActionFailsClosed() throws {
        let descriptor = try command()
        #expect(throws: HostDescriptorPolicyError.unknownAction) {
            try HostDescriptorPolicy.authorize(descriptor: descriptor, actionID: "test.action.unregistered",
                resourceScope: scope, caller: .user, callerInstanceID: "synthetic.ui")
        }
    }

    @Test("声明副作用仍要求宿主批准，纯只读无需批准")
    func approvalIsNotImpliedByDescriptor() throws {
        let network = try command(effects: [.network])
        #expect(throws: ExecutionPolicyError.sideEffectApprovalRequired) {
            try HostDescriptorPolicy.authorize(descriptor: network, resourceScope: scope,
                caller: .user, callerInstanceID: "synthetic.ui")
        }
        let read = try command()
        try HostDescriptorPolicy.authorize(descriptor: read, resourceScope: .none,
            caller: .user, callerInstanceID: "synthetic.ui")
    }

    @Test("UI 策略不能被 Agent 或 Workflow 身份借用")
    func UIEntryCannotExpandCallers() throws {
        let descriptor = try command()
        for caller in [ExecutionCaller.agent, .workflow] {
            #expect(throws: ExecutionPolicyError.callerMismatch) {
                try HostDescriptorPolicy.authorize(descriptor: descriptor, resourceScope: .none,
                    caller: caller, callerInstanceID: "synthetic.external", sideEffectsApproved: true)
            }
        }
    }

    @Test("AI 打开动作在未配置 API/无输入时仍可用，执行另行拒绝")
    func prepareAndRunAreSeparate() throws {
        let descriptor = try HostActionCatalog.descriptor(id: "test.command.ai", title: "Synthetic AI",
            operations: [.prepareAI, .generateText],
            actionAvailability: [.generateText: .unavailable(reasonKey: "API configuration required")])
        let opened = try HostDescriptorPolicy.authorize(descriptor: descriptor, resourceScope: .none,
            caller: .user, callerInstanceID: "synthetic.ui")
        #expect(opened.effects == [.read] && opened.actionID == "keydock.action.prepareAI")
        #expect(throws: HostDescriptorPolicyError.unavailable(reasonKey: "API configuration required")) {
            try HostDescriptorPolicy.authorize(descriptor: descriptor, actionID: "keydock.action.generateText",
                availableContext: [.explicitInput], resourceScope: scope,
                caller: .user, callerInstanceID: "synthetic.ui", sideEffectsApproved: true)
        }
    }

    @Test("同一 AI 声明的 run 动作被消费且不能缺少输入上下文")
    func selectedRunActionRequiresInput() throws {
        let descriptor = try HostActionCatalog.descriptor(id: "test.command.ai", title: "Synthetic AI",
            operations: [.prepareAI, .generateText])
        #expect(throws: HostDescriptorPolicyError.missingContext([.explicitInput])) {
            try HostDescriptorPolicy.authorize(descriptor: descriptor, actionID: "keydock.action.generateText",
                resourceScope: scope, caller: .user, callerInstanceID: "synthetic.ui", sideEffectsApproved: true)
        }
        let request = try HostDescriptorPolicy.authorize(descriptor: descriptor, actionID: "keydock.action.generateText",
            availableContext: [.explicitInput], resourceScope: scope, caller: .user,
            callerInstanceID: "synthetic.ui", sideEffectsApproved: true)
        #expect(request.effects == [.network] && request.toolID == "keydock.tool.generateText")
    }
}
