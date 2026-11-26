import Foundation
import AICore
import ExecutionCore

public enum AgentToolError: Error, Equatable, Sendable { case denied, approvalTimedOut, duplicateCall, missingJournal, toolFailed, invalidDefinition, receiptUnavailable }

/// 宿主定义，不可从模型数据解码；描述与效果在创建运行时冻结。
public struct ScopedAITool: Sendable {
    public let definition: AIToolDefinition
    public let version: Int
    public let executionToolID: String?
    public let actionID: String?
    public let actionVersion: Int?
    public let effects: Set<ExecutionEffect>
    public let resource: ExecutionResourceScope
    public let approvalSummary: String
    public let invoke: @Sendable ([String: JSONValue], UUID) async throws -> String
    public init(definition: AIToolDefinition, version: Int = 1, executionToolID:String? = nil, actionID:String? = nil, actionVersion:Int? = nil, effects: Set<ExecutionEffect>, resource: ExecutionResourceScope,
                approvalSummary: String, invoke: @escaping @Sendable ([String: JSONValue], UUID) async throws -> String) {
        self.definition = definition; self.version = version; self.effects = effects; self.resource = resource
        self.executionToolID = executionToolID; self.actionID = actionID; self.actionVersion = actionVersion
        self.approvalSummary = approvalSummary; self.invoke = invoke
    }
}
public struct AgentToolApproval: Identifiable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let toolName: String
    public let summary: String
    public let effects: Set<ExecutionEffect>
    public let runContractFingerprint: String?
    public let maxRunTokens: Int?
    public init(id: UUID, runID: UUID, toolName: String, summary: String, effects: Set<ExecutionEffect>, runContractFingerprint: String? = nil, maxRunTokens: Int? = nil) {
        self.id = id; self.runID = runID; self.toolName = toolName; self.summary = summary; self.effects = effects
        self.runContractFingerprint = runContractFingerprint; self.maxRunTokens = maxRunTokens
    }
}

/// 副作用经逐次用户批准并先落intent。远端annotations与模型参数不能创建授权。
public actor ScopedToolBroker: AgentToolRouting {
    private let tools: [String: ScopedAITool]
    private let runID: UUID
    private let approve: @Sendable (AgentToolApproval) async throws -> Bool
    private let journal: InvocationStore
    private let approvalTimeout: Duration
    private let runContractFingerprint: String?
    private let maxRunTokens: Int?
    private var seen: Set<String> = []
    private var active: [UUID: Task<String, any Error>] = [:]
    private var closed = false
    private var uncertainInvocationIDs: Set<UUID> = []
    public init(runID: UUID, tools: [ScopedAITool], journal: InvocationStore,
                approvalTimeout: Duration = .seconds(90), runContractFingerprint: String? = nil, maxRunTokens: Int? = nil,
                approve: @escaping @Sendable (AgentToolApproval) async throws -> Bool) throws {
        var entries: [String: ScopedAITool] = [:]
        guard tools.count <= 64, approvalTimeout > .zero else { throw AgentToolError.invalidDefinition }
        guard runContractFingerprint.map({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) ?? true,
              maxRunTokens.map({ (1...RunTokenBudgetSnapshot.maximumThreshold).contains($0) && runContractFingerprint != nil }) ?? true else { throw AgentToolError.invalidDefinition }
        for tool in tools {
            guard tool.definition.name.range(of:"^[A-Za-z0-9_-]{1,64}$",options:.regularExpression) != nil,
                  tool.version > 0, !tool.effects.isEmpty, entries[tool.definition.name] == nil,
                  tool.approvalSummary.utf8.count <= 16_384 else { throw AgentToolError.invalidDefinition }
            guard tool.executionToolID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
                  tool.actionID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
                  tool.actionVersion.map({$0 > 0}) ?? true,
                  (tool.actionID == nil) == (tool.actionVersion == nil) else { throw AgentToolError.invalidDefinition }
            try ToolJSONSchema.checkSchema(tool.definition.parameters)
            entries[tool.definition.name] = tool
        }
        self.runID = runID; self.tools = entries; self.journal = journal; self.approvalTimeout = approvalTimeout; self.approve = approve
        self.runContractFingerprint = runContractFingerprint; self.maxRunTokens = maxRunTokens
    }
    public func definitions() -> [AIToolDefinition] { tools.keys.sorted().compactMap { tools[$0]?.definition } }
    public func invoke(_ call: AIToolCall, allowed: Set<String>) async throws -> String {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard allowed.contains(call.name), let tool = tools[call.name] else { throw AIProviderError.unknownTool }
        guard !call.id.isEmpty, call.id.utf8.count <= 512, seen.insert(call.id).inserted else { throw AgentToolError.duplicateCall }
        guard call.arguments.utf8.count <= 65_536, let arguments = try? JSONDecoder().decode([String:JSONValue].self,from:Data(call.arguments.utf8)) else { throw AIProviderError.invalidToolArguments }
        try ToolJSONSchema.validate(.object(arguments),schema:tool.definition.parameters)
        let id = UUID()
        let task = Task { try await self.perform(call,arguments:arguments,tool:tool,id:id) }
        active[id] = task
        defer { active[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func close(cancel: Bool) async {
        closed = true
        let handles = Array(active.values)
        if cancel { for handle in handles { handle.cancel() } }
        for handle in handles { _ = await handle.result }
    }
    public func unknownInvocationCount() -> Int { uncertainInvocationIDs.count }
    private func perform(_ call: AIToolCall, arguments: [String:JSONValue], tool: ScopedAITool, id: UUID) async throws -> String {
        try Task.checkCancellation()
        let effectful = tool.effects.contains { !$0.isReadOnly }
        if effectful {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
            let argumentPreview = String(decoding:try encoder.encode(arguments),as:UTF8.self)
            let proposal = AgentToolApproval(id:id,runID:runID,toolName:call.name,summary:tool.approvalSummary+"\n"+argumentPreview,effects:tool.effects,runContractFingerprint:runContractFingerprint,maxRunTokens:maxRunTokens)
            let approved = try await withThrowingTaskGroup(of:Bool.self) { group in
                group.addTask { try await self.approve(proposal) }
                group.addTask { try await Task.sleep(for:self.approvalTimeout); throw AgentToolError.approvalTimedOut }
                defer { group.cancelAll() }; return try await group.next() ?? false
            }
            try Task.checkCancellation()
            guard approved else { throw AgentToolError.denied }
        }
        let command = "keydock.agent." + runID.uuidString
        let request = ExecutionRequest(invocationID:id,commandID:command,commandVersion:1,toolID:tool.executionToolID ?? "keydock.agenttool."+call.name,toolVersion:tool.version,caller:.agent,callerInstanceID:runID.uuidString,resourceScope:tool.resource,effects:tool.effects,actionID:tool.actionID,actionVersion:tool.actionVersion)
        let grant = PolicyGrant(caller:.agent,callerInstanceID:runID.uuidString,commandID:command,commandVersion:1,toolID:request.toolID,toolVersion:tool.version,resourceScope:tool.resource,allowedEffects:tool.effects,expiresAt:Date().addingTimeInterval(30),sideEffectsApproved:effectful,invocationID:id,actionID:request.actionID,actionVersion:request.actionVersion,agentInvocationApproved:effectful)
        try ExecutionPolicy.authorize(request:request,grant:grant)
        try Task.checkCancellation()
        do { try await journal.begin(id:id,name:call.name,commandID:command,commandVersion:1,configurationFingerprint:runContractFingerprint,caller:"agent",initialMessage:"agent.toolIntent") }
        catch { await journal.abandonUndispatched(id); throw error }
        let result: String
        var dispatched = false
        do {
            try Task.checkCancellation()
            dispatched = true
            result = try await tool.invoke(arguments,id)
        } catch {
            // 已派发的调用抛错不能证明副作用未发生，远端断连尤其必须保留unknown。
            if dispatched { uncertainInvocationIDs.insert(id) }
            try? await journal.finish(id:id,result:.init(state:dispatched ? .interrupted:.cancelled,message:dispatched ? "agent.toolOutcomeUnknown":"agent.toolNotDispatched"))
            await journal.releaseProtection(for:id)
            throw error
        }
        do { try await journal.finish(id:id,result:.init(state:.succeeded,message:"agent.toolCompleted")) }
        catch { uncertainInvocationIDs.insert(id); await journal.releaseProtection(for:id); throw AgentToolError.receiptUnavailable }
        await journal.releaseProtection(for:id)
        try Task.checkCancellation()
        guard result.utf8.count <= 65_536 else { throw AIProviderError.outputLimit }
        return result
    }
}
