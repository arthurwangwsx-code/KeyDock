import Foundation
import ExecutionCore
import AgentCore
import AutomationCore
import AICore
import MCPAdapters

private struct AttemptDependencies: Encodable {
    struct Provider: Encodable { let definitionID: UUID; let configuration: AIProviderConfiguration; let settingsFingerprint: String }
    let schemaVersion = 1
    var commands: [RunDefinitionReference] = []
    var actions: [RunDefinitionReference] = []
    var providers: [Provider] = []
    var contribution: FrozenCommandContribution?
    var mcp: [AttemptMCPScope] = []
}

@MainActor private final class AttemptAdmissionWaiter {
    var context: AttemptExecutionContext?
    var cancelled = false
    func cancel() { cancelled = true; context?.fail(CancellationError()) }
}

extension WorkbenchModel {
    var attemptReviewStamp: AttemptReviewStamp {
        .init(history: historyGeneration, configuration: configurationExportGeneration, contribution: contributionEpoch,
              mcp: mcpGeneration, catalogs: mcpCatalogEpoch)
    }
    func receiptStore(_ kind: AttemptReceiptStore) -> InvocationStore { kind == .cli ? invocationStore : aiInvocationStore }
    func savedRunReference(_ definition: SavedRunDefinition) -> RunDefinitionReference? {
        guard let proposed = try? definition.reference,
              let current = SavedRunDefinition.resolve(proposed, in: configuration),
              let actual = try? current.reference, actual == proposed else { return nil }
        return actual
    }
    func isCurrentAttemptReview(_ review: AttemptPreparationReview) -> Bool {
        guard !isDesktopReview else { return false }
        guard !isShuttingDown, !isClearingHistory, attemptReviewStamp == review.stamp,
              !executionReservations.contains(review.origin.invocationID), taskHandles[review.origin.invocationID] == nil,
              let current = SavedRunDefinition.resolve(review.definition, in: configuration),
              (try? current.reference) == review.definition else { return false }
        for scope in review.mcpScopes {
            let sources = configuration.mcpServers.filter { $0.id == scope.serverID }
            guard sources.count == 1, sources[0].enabled, sources[0].revision == scope.configurationRevision,
                  !mcpSessionDisabled.contains(scope.serverID), mcpSettingsOwner == nil,
                  mcpCatalogs[scope.serverID]?.revision.utf8.elementsEqual(scope.catalogRevision.utf8) == true else { return false }
        }
        if case .agent(let definition) = current {
            guard mcpSettingsOwner == nil, !mcpSettingsChanging, definition.allowedMCPServerIDs.isDisjoint(with: mcpSessionDisabled),
                  definition.allowedMCPServerIDs.allSatisfy({ id in configuration.mcpServers.filter { $0.id == id && $0.enabled }.count == 1 }) else { return false }
        }
        return true
    }
    func reviewAttempt(_ origin: AttemptOrigin) async throws -> AttemptPreparationReview {
        try requireGeneralRuntime()
        guard !isShuttingDown, !isClearingHistory else { throw AttemptPreparationError.changed }
        guard !executionReservations.contains(origin.invocationID), taskHandles[origin.invocationID] == nil else { throw AttemptPreparationError.busy }
        let stamp = attemptReviewStamp
        let checked = try await receiptStore(origin.store).inspectRecovery(origin.invocationID)
        guard attemptReviewStamp == stamp, !isShuttingDown, !isClearingHistory, !Task.isCancelled else { throw AttemptPreparationError.changed }
        guard let previous = checked.receipt.runAttempt?.definition,
              (previous.kind == .savedCommand) == (origin.store == .cli),
              let definition = SavedRunDefinition.resolve(previous, in: configuration) else { throw AttemptPreparationError.unavailable }
        let current = try definition.reference
        var dependencies = AttemptDependencies(), lines: [AttemptScopeLine] = []
        var requiresInput = false, allowsInput = true, previews: [String] = []
        let previewEncoder = JSONEncoder(); previewEncoder.outputFormatting = [.withoutEscapingSlashes]
        func command(_ value: SavedCommand) throws {
            try value.validate(); dependencies.commands.append(try RunDefinitionFingerprint.reference(value))
            lines.append(.init(kind: .command, value: value.name))
            let args = String(decoding: try previewEncoder.encode([value.executable] + value.arguments), as: UTF8.self)
            let keys = value.environment.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.joined(separator: ", ")
            previews.append(value.name + "\n" + args + "\n" + L("Working directory") + ": " + value.workingDirectory + "\n" + L("Environment overrides") + ": " + keys)
        }
        func action(_ value: AIActionPreset, scene: AIScene? = nil) throws {
            let settings = try resolveAISettings(action: value, scene: scene)
            let service = settings.configuration
            dependencies.actions.append(try RunDefinitionFingerprint.reference(value))
            dependencies.providers.append(.init(definitionID: value.id, configuration: service, settingsFingerprint: settings.fingerprint))
            lines.append(.init(kind: .service, value: (service.endpoint.host ?? "") + service.endpoint.path + " · " + service.model))
            previews.append(value.displayName + "\n" + value.prompt)
        }
        func uniqueCommand(_ id: UUID) throws -> SavedCommand {
            let matches = configuration.savedCommands.filter { $0.id == id }
            guard matches.count == 1 else { throw AttemptPreparationError.unavailable }; return matches[0]
        }
        func uniqueAction(_ id: UUID) throws -> AIActionPreset {
            let matches = configuration.aiActions.filter { $0.id == id }
            guard matches.count == 1 else { throw AttemptPreparationError.unavailable }; return matches[0]
        }
        switch definition {
        case .command(let value):
            try command(value); dependencies.contribution = try FrozenCommandContribution(prepareCommandContribution(value))
            allowsInput = false
            lines.append(.init(kind: .directory, value: value.workingDirectory))
            lines.append(.init(kind: .environment, value: String(value.environment.count)))
            lines.append(.init(kind: .budget, value: String(value.timeout) + " s"))
        case .action(let value):
            try action(value); requiresInput = true
        case .agent(let value):
            try value.validate(); requiresInput = true
            guard value.allowedMCPToolNames.allSatisfy({ name in MCPToolReference.validName(name) && value.allowedMCPServerIDs.filter { MCPToolReference.references(name, sourceID: $0) }.count == 1 }) else { throw AttemptPreparationError.unavailable }
            let settings = try resolveAISettings(scene: .agent, override: value.modelOptions ?? .init(), legacyModelOverride: value.modelOptions == nil ? value.modelOverride : "", requiresTools: true)
            let service = settings.configuration
            dependencies.providers.append(.init(definitionID: value.id, configuration: service, settingsFingerprint: settings.fingerprint))
            lines.append(.init(kind: .service, value: (service.endpoint.host ?? "") + service.endpoint.path + " · " + service.model))
            previews.append(value.name + "\n" + value.instructions)
            lines.append(.init(kind: .builtIn, value: L("Current time")))
            for id in value.allowedCommandIDs.sorted(by: { $0.uuidString < $1.uuidString }) { try command(uniqueCommand(id)) }
            if !dependencies.commands.isEmpty { dependencies.contribution = try FrozenCommandContribution(requireCommandContribution()) }
            guard mcpSettingsOwner == nil, !mcpSettingsChanging else { throw AttemptPreparationError.busy }
            var resolved: Set<String> = []
            for id in value.allowedMCPServerIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let sources = configuration.mcpServers.filter { $0.id == id }
                guard sources.count == 1, let source = sources.first, source.enabled, !mcpSessionDisabled.contains(id) else { throw AttemptPreparationError.unavailable }
                try source.validateStructure()
                let names = Set(value.allowedMCPToolNames.filter { MCPToolReference.references($0, sourceID: id) })
                resolved.formUnion(names)
                if names.isEmpty { continue }
                if let launch = source.stdioLaunch {
                    let args = String(decoding: try previewEncoder.encode([launch.executable] + launch.arguments), as: UTF8.self)
                    previews.append(source.name + "\n" + args + "\n" + L("Working directory") + ": " + launch.workingDirectory)
                }
                guard let catalog = mcpCatalogs[id], catalog.serverID == id, catalog.configurationRevision == source.revision else { throw AttemptPreparationError.needsMCPConnection }
                dependencies.mcp.append(.init(serverID: id, configurationRevision: source.revision,
                    selectedNames: names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, catalogRevision: catalog.revision,
                    contractDigest: try catalog.selectedContractDigest(names: names)))
                for name in names.sorted() {
                    guard let tool = catalog.tools.first(where: { $0.definition.name == name }) else { throw AttemptPreparationError.unavailable }
                    lines.append(.init(kind: .tools, value: source.name + " · " + tool.originalName))
                    previews.append(source.name + " · " + (source.endpoint.host ?? "") + source.endpoint.path + "\n" + tool.originalName + "\n" + tool.definition.description)
                }
            }
            guard resolved == value.allowedMCPToolNames else { throw AttemptPreparationError.unavailable }
            lines.append(.init(kind: .budget, value: String(value.timeoutSeconds) + " s"))
            lines.append(.init(kind: .turns, value: String(value.maxTurns)))
            lines.append(.init(kind: .calls, value: String(value.maxToolCalls)))
        case .workflow(let value):
            let plan = try compileWorkflow(value)
            let commands = Set(value.steps.compactMap { if case .savedCommand(let id) = $0.operation { id } else { nil as UUID? } })
            let actions = Set(value.steps.compactMap { if case .aiAction(let id) = $0.operation { id } else { nil as UUID? } })
            for id in commands.sorted(by: { $0.uuidString < $1.uuidString }) { try command(uniqueCommand(id)) }
            for id in actions.sorted(by: { $0.uuidString < $1.uuidString }) { try action(uniqueAction(id), scene: .workflow) }
            if !commands.isEmpty { dependencies.contribution = try FrozenCommandContribution(requireCommandContribution()) }
            var ordered: [String] = []
            for (index, step) in value.steps.enumerated() {
                let operation: String
                switch step.operation {
                case .savedCommand(let id): operation = try uniqueCommand(id).name
                case .aiAction(let id): operation = try uniqueAction(id).displayName
                case .manualInput: operation = L("Ask for input")
                case .transform(let transform):
                    switch transform { case .trim: operation = L("Trim text"); case .uppercase: operation = L("Uppercase"); case .lowercase: operation = L("Lowercase") }
                }
                let binding: String
                switch step.input {
                case .workflowInput: binding = L("Workflow input")
                case .previousOutput: binding = L("Previous output")
                case .literal(let text): binding = L("Literal text") + ": " + text
                }
                ordered.append(String(index + 1) + ". " + operation + " · " + binding)
            }
            previews.insert(ordered.joined(separator: "\n"), at: 0)
            requiresInput = plan.requiresInitialInput(commandsUsingInput: Set(configuration.savedCommands.filter { $0.arguments.contains("{{input}}") }.map(\.id)))
            lines.append(.init(kind: .steps, value: String(value.steps.count)))
            lines.append(.init(kind: .budget, value: String(plan.limits.wallTimeout) + " s"))
        }
        guard let fingerprint = SavedItemIdentity.fingerprint(dependencies) else { throw AttemptPreparationError.unavailable }
        let preview = previews.joined(separator: "\n\n")
        guard lines.reduce(0, { $0 + $1.value.utf8.count }) + preview.utf8.count <= 1_048_576 else { throw AttemptPreparationError.scopeTooLarge }
        return .init(origin: origin, recovery: checked, definition: current, stamp: stamp,
            dependencyFingerprint: fingerprint, mcpScopes: dependencies.mcp, title: definition.name, lines: lines,
            scopePreview: preview, allowsInput: allowsInput, requiresInput: requiresInput)
    }

    func publishAttempt(_ begun: InvocationBeginReceipt, context: AttemptExecutionContext?) {
        if let index = tasks.firstIndex(where: { $0.id == begun.receipt.id }) { tasks[index].runAttempt = begun.receipt.runAttempt }
    }

    func beginOwnedReceipt(store: InvocationStore, id: UUID, name: String, authorization: ExecutionRequest,
                           configurationFingerprint: String? = nil, initialMessage: String = "",
                           runDefinition: RunDefinitionReference? = nil, attempt: AttemptExecutionContext? = nil,
                           materialCapture: TaskMaterialCapture? = nil) async throws -> InvocationWorkerOwnership {
        var owner: InvocationWorkerOwnership?
        do {
            // 新尝试在取消／关闭时不得消费旧审阅；普通已接纳任务仍写入取消终态所需的intent。
            if let attempt { try Task.checkCancellation(); try attempt.validate(in: self) }
            if let attempt { guard attempt.id == id, attempt.review.definition == runDefinition else { throw AttemptPreparationError.changed } }
            let begun = try await store.begin(id: id, name: name, commandID: authorization.commandID,
                commandVersion: authorization.commandVersion, configurationFingerprint: configurationFingerprint,
                caller: authorization.caller.rawValue, initialMessage: initialMessage, runDefinition: runDefinition,
                recovering: attempt?.review.recovery)
            let ownership = InvocationWorkerOwnership(store: store, begun: begun); owner = ownership
            publishAttempt(begun, context: attempt)
            if let attempt {
                try Task.checkCancellation(); try attempt.validate(in: self)
                guard !isShuttingDown, !cancelledTaskIDs.contains(id) else { throw CancellationError() }
                try attempt.accept(ownership, in: self)
            }
            if let materialCapture, taskMaterialCaptures[id] === materialCapture,
               let task = tasks.first(where: { $0.id == id }) {
                materialCapture.bind(begun, namespace: task.receiptIsAI ? .ai : .cli)
            }
            return ownership
        } catch {
            if let materialCapture {
                materialCapture.revoke()
                if taskMaterialCaptures[id] === materialCapture { taskMaterialCaptures[id] = nil }
            }
            if let owner { await owner.abandon() }
            else if let failure = error as? InvocationBeginFailure { await store.abandonUndispatched(id, expectedRunStamp: failure.undispatchedStamp) }
            else if runDefinition == nil { await store.abandonUndispatched(id) }
            attempt?.fail(error)
            throw error
        }
    }

    func admitAttempt(_ review: AttemptPreparationReview, input: String, isCurrent: @escaping @MainActor () -> Bool,
                      didAdmit: @escaping @MainActor (UUID) -> Void = { _ in }) async throws -> InvocationWorkerOwnership {
        guard isCurrent(), isCurrentAttemptReview(review), input.utf8.count <= TaskTextLimits.inputBytes,
              !review.requiresInput || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let definition = SavedRunDefinition.resolve(review.definition, in: configuration) else { throw AttemptPreparationError.changed }
        let waiter = AttemptAdmissionWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ticket = AttemptExecutionContext(review: review, input: input, isCurrent: isCurrent, completion: {
                    if case .success(let owner) = $0 { didAdmit(owner.id) }
                    continuation.resume(with: $0)
                })
                waiter.context = ticket
                guard !waiter.cancelled, !Task.isCancelled else { ticket.fail(CancellationError()); return }
                let launched: UUID?
                switch definition {
                case .command(let value): launched = runCommand(value, caller: .user, showWorkspace: false, attempt: ticket)
                case .action(let value):
                    let draft = createDraft(actionID: value.id, input: input, source: .manual)
                    launched = ownsDraft(draft) ? runAI(action: value, draft: draft, caller: .user, attempt: ticket) : nil
                case .agent(let value): launched = runAgent(value, input: input, attempt: ticket)
                case .workflow(let value): launched = runWorkflow(value, input: input, interaction: true, runID: ticket.id, attempt: ticket)
                }
                if launched != ticket.id { ticket.fail(AttemptPreparationError.admissionFailed) }
            }
        } onCancel: {
            Task { @MainActor in waiter.cancel() }
        }
    }
}
