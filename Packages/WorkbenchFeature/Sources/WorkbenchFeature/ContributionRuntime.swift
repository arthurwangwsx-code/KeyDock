import Foundation
import CommandCore
import ExecutionCore
import MacAdapters

public enum BuiltinContributionID {
    public static let calculator = "keydock.contribution.calculator"
    public static let commands = "keydock.contribution.commands"
    public static let files = "keydock.contribution.files"
}

public struct ContributionPresentation: Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let enabled: Bool
}

enum ContributionOutcome {
    case completed, started(UUID), rejected
    var accepted: Bool { if case .rejected = self { false } else { true } }
    var taskID: UUID? { if case .started(let id) = self { id } else { nil } }
}

@MainActor struct ContributionQuerySource {
    let provider: any CommandProviding
    let prepareSelection: @MainActor (CommandItem,ContributionSelectionContext) async throws -> Any
}

@MainActor struct ContributionSelectionContext { let stillCurrent: @MainActor ()->Bool }
struct ContributionQueryOptions: Sendable {
    let resultLimit: Int
    let minimumQueryCharacters: Int
}

@MainActor struct ContributionQueryPlan {
    let epoch: UUID
    let sources: [String: ContributionQuerySource]
    var providers: [any CommandProviding] { sources.keys.sorted().compactMap { sources[$0]?.provider } }
}

@MainActor struct ContributionProviderRegistration {
    let manifest: ContributionManifest
    let presentation: @MainActor ()->(String,String)
    let dismissAfterSelection: Bool
    let catalogItems: @MainActor (WorkbenchModel,ContributionCatalogSnapshot) throws -> [CommandItem]
    let querySource: @MainActor (AppConfiguration,ContributionCatalogSnapshot,FileSearchService?,ContributionQueryOptions) throws -> ContributionQuerySource?
    let prepareItem: (@MainActor (WorkbenchModel,CommandItem) throws -> Any)?
    let read: (@MainActor (Any) throws -> Any)?
}

@MainActor enum ContributionHandlerBody {
    case immediate(@MainActor (WorkbenchModel,ResolvedContributionAction,Any,ExecutionCaller) throws -> ContributionOutcome)
    case asynchronous(@MainActor (WorkbenchModel,ResolvedContributionAction,Any,ExecutionCaller) async throws -> ContributionOutcome)
}

@MainActor struct ContributionHandlerRegistration {
    let contract: ContributionHandlerContract
    let body: ContributionHandlerBody
}

@MainActor struct BuiltinContributionDefinition {
    let provider: ContributionProviderRegistration
    let handlers: [ContributionHandlerRegistration]
}

/// 只有此编译期组合根注册实现；新增工具不改WorkbenchModel的能力switch。
@MainActor struct WorkbenchContributionRuntime {
    let catalog: CompiledContributionCatalog
    let providers: [ContributionProviderRegistration]
    let handlers: [CommandExecutionReference: ContributionHandlerRegistration]
    init() throws {
        let definitions = try [CalculatorContribution.definition(), SavedCommandContribution.definition(), FileSearchContribution.definition()]
        providers = definitions.map(\.provider)
        let implementations = definitions.flatMap(\.handlers)
        catalog = try CompiledContributionCatalog(manifests:providers.map(\.manifest),providers:providers.map { $0.manifest.provider },handlers:implementations.map(\.contract))
        handlers = Dictionary(uniqueKeysWithValues:implementations.map { ($0.contract.reference,$0) })
    }
    func owner(of id:String) -> ContributionProviderRegistration? { providers.first { $0.manifest.ownsCommandID(id) } }
    func owner(of item:CommandItem) -> ContributionProviderRegistration? { providers.first { $0.manifest.owns(item) } }
    func queryPlan(configuration:AppConfiguration,snapshot:ContributionCatalogSnapshot,files:FileSearchService?,options:ContributionQueryOptions = .init(resultLimit:30,minimumQueryCharacters:2)) throws -> ContributionQueryPlan {
        var sources: [String:ContributionQuerySource] = [:]
        for provider in providers where snapshot.isEnabled(provider.manifest.reference.toolID) {
            if let source = try provider.querySource(configuration,snapshot,files,options) { sources[provider.manifest.reference.toolID] = source }
        }
        return .init(epoch:snapshot.epoch,sources:sources)
    }
    func invoke(_ resolved:ResolvedContributionAction,payload:Any,store:WorkbenchModel,caller:ExecutionCaller) throws -> ContributionOutcome {
        try validateCurrent(resolved,store:store)
        guard let handler = handlers[resolved.action.execution], case .immediate(let body) = handler.body else { throw ContributionCatalogError.handlerUnavailable }
        return try body(store,resolved,payload,caller)
    }
    func invokeAsync(_ resolved:ResolvedContributionAction,payload:Any,store:WorkbenchModel,caller:ExecutionCaller) async throws -> ContributionOutcome {
        try validateCurrent(resolved,store:store)
        guard let handler = handlers[resolved.action.execution] else { throw ContributionCatalogError.handlerUnavailable }
        switch handler.body {
        case .immediate(let body): return try body(store,resolved,payload,caller)
        case .asynchronous(let body): return try await body(store,resolved,payload,caller)
        }
    }
    private func validateCurrent(_ resolved:ResolvedContributionAction,store:WorkbenchModel) throws {
        guard !store.isShuttingDown, !Task.isCancelled, store.contributionEpoch == resolved.epoch,
              store.contributionSnapshot.isEnabled(resolved.manifest.reference.toolID) else { throw ContributionCatalogError.staleSnapshot }
    }
}

extension WorkbenchModel {
    var contributionSnapshot: ContributionCatalogSnapshot { contributions.catalog.snapshot(disabled:configuration.disabledContributions,epoch:contributionEpoch) }
    public var contributionPresentations: [ContributionPresentation] {
        contributions.providers.map { provider in
            let (title,detail) = provider.presentation(), id = provider.manifest.reference.toolID
            return .init(id:id,title:title,detail:detail,enabled:contributionSnapshot.isEnabled(id))
        }
    }
    public func isContributionEnabled(_ id:String) -> Bool { contributionSnapshot.isEnabled(id) }
    @discardableResult public func setContributionEnabled(_ enabled:Bool,id:String) -> Bool {
        guard contributions.catalog.manifests.contains(where:{$0.reference.toolID == id}) else { return false }
        var next = configuration
        if enabled { next.disabledContributions.remove(id) } else { next.disabledContributions.insert(id) }
        return commitShortcutConfiguration(next)
    }
    func contributionItems() -> [CommandItem] {
        let snapshot = contributionSnapshot
        return contributions.providers.filter { snapshot.isEnabled($0.manifest.reference.toolID) }.flatMap { (try? $0.catalogItems(self,snapshot)) ?? [] }
    }
    func resolveContribution(_ binding:CommandContributionBinding,id:String,title:String,keywords:[String] = []) throws -> ResolvedContributionAction {
        guard !isShuttingDown else { throw WorkbenchLifecycleError.shuttingDown }
        return try contributionSnapshot.resolve(binding,instanceID:"keydock.command."+fingerprint(id),title:title,keywords:keywords)
    }
    @discardableResult func authorizeContribution(_ resolved:ResolvedContributionAction,resource:String,context:Set<CommandContextRequirement> = [],caller:ExecutionCaller,invocation:UUID = UUID()) throws -> ExecutionRequest {
        guard !isShuttingDown else { throw WorkbenchLifecycleError.shuttingDown }
        return try HostDescriptorPolicy.authorize(descriptor:resolved.descriptor,actionID:resolved.action.id,availableContext:context,
            resourceScope:.exact(namespace:"keydock.resource",identifier:fingerprint(resource)),caller:caller,
            callerInstanceID:caller == .shortcut ? "shortcut."+fingerprint(resolved.descriptor.id) : "interactive-ui",invocationID:invocation,sideEffectsApproved:true)
    }
    /// 已解析的在途运行无需重解析最新版；新UI请求必须先经过当前snapshot。
    func executeContributionItem(_ item:CommandItem,caller:ExecutionCaller) -> Bool {
        guard let provider = contributions.owner(of:item) else {
            if item.contribution != nil { contributionUnavailable(); return true }; return false
        }
        do {
            guard let binding = item.contribution, binding.reference.contribution == provider.manifest.reference,
                  let prepare = provider.prepareItem else { throw ContributionCatalogError.unavailable }
            let resolved = try resolveContribution(binding,id:item.id,title:item.title,keywords:item.keywords)
            let outcome = try contributions.invoke(resolved,payload:prepare(self,item),store:self,caller:caller)
            if outcome.accepted { recordContributionSelection(item.id,supersedesDesktop:provider.dismissAfterSelection); if provider.dismissAfterSelection { onDismiss?(true) } }
        } catch { contributionUnavailable() }
        return true
    }
    @discardableResult func dispatchContributionSelection(_ item:CommandItem,plan:ContributionQueryPlan,stillCurrent:@escaping @MainActor ()->Bool) -> Bool {
        guard let binding = item.contribution, let source = plan.sources[binding.reference.contribution.toolID] else { return false }
        guard !isShuttingDown, contributionActionTasks.count < sessionLimits.activeTasks else { admissionNotice(); return true }
        let id = UUID()
        contributionActionTasks[id] = Task { [weak self] in
            guard let self else { return }; defer { contributionActionTasks[id] = nil }
            guard !Task.isCancelled, stillCurrent(), self.contributionEpoch == plan.epoch else { return }
            do {
                let resolved = try resolveContribution(binding,id:item.id,title:item.title,keywords:item.keywords)
                let payload = try await source.prepareSelection(item,.init(stillCurrent:stillCurrent))
                guard !Task.isCancelled, stillCurrent(), contributionEpoch == plan.epoch else { return }
                let outcome = try await contributions.invokeAsync(resolved,payload:payload,store:self,caller:.user)
                if outcome.accepted {
                    let dismiss = contributions.owner(of:item)?.dismissAfterSelection == true
                    recordContributionSelection(item.id,supersedesDesktop:dismiss); if dismiss { onDismiss?(true) }
                }
            } catch { if stillCurrent() { contributionUnavailable() } }
        }
        return true
    }
    private func recordContributionSelection(_ id:String,supersedesDesktop:Bool) {
        if supersedesDesktop { cancelDesktopWorkspaceRuns(); invalidateLauncherReplies() }
        configuration.preferences.recent[id] = Date(); save()
    }
    func contributionUnavailable() {
        let notice = noticeKey("This tool or result is unavailable. Enable the tool or search again.")
        launcherNoticeMessage = notice; workspaceNoticeMessage = notice
    }
}
