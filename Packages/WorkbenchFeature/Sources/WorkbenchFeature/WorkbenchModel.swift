import AppKit
import SwiftUI
import CommandCore
import ExecutionCore
import AICore
import MacAdapters
import KeyDockUI
import AgentCore
import AutomationCore
import MCPAdapters

enum WorkbenchLifecycleError: Error { case shuttingDown }

/// 唯一业务 Store：共享服务、配置、任务与文档；窗口导航、搜索和编辑状态由各 Session 拥有。
@MainActor public final class WorkbenchModel: ObservableObject {
    @Published public private(set) var isShuttingDown = false
    @Published public var shortcutsUnavailable = false
    @Published public var configuration: AppConfiguration
    @Published public private(set) var catalog: [CommandItem] = []
    @Published public private(set) var clipboardRevision: UInt64 = 0
    @Published private var clipboardCaptureIssue: ClipboardRejection?
    @Published public private(set) var clipboardPauseNeedsPersistence = false
    public var clipboardCaptureNotice: String {
        if clipboardPauseNeedsPersistence { return L("Clipboard recording is paused for this session because settings could not be saved. The previous recording setting may return after restarting. Save settings again before restarting.") }
        return switch clipboardCaptureIssue {
        case .capacity: L("The last clipboard item was not recorded: history is full. Delete or unpin some items to make room.")
        case .itemTooLarge: L("The last clipboard item was not recorded: it exceeds the 1 MiB text limit.")
        case nil: ""
        }
    }
    @Published public var tasks: [RunningTaskItem] = []
    @Published public var launcherNoticeMessage: LocalizedNotice = .none
    public var launcherNotice: String {
        get { launcherNoticeMessage.rendered() }
        set { launcherNoticeMessage = .verbatim(newValue) }
    }
    @Published public var settingsNoticeMessage: LocalizedNotice = .none
    public var settingsNotice: String {
        get { settingsNoticeMessage.rendered() }
        set { settingsNoticeMessage = .verbatim(newValue) }
    }
    @Published public var workspaceNoticeMessage: LocalizedNotice = .none
    public var workspaceNotice: String {
        get { workspaceNoticeMessage.rendered() }
        set { workspaceNoticeMessage = .verbatim(newValue) }
    }
    @Published public private(set) var applicationIndexNoticeMessage: LocalizedNotice = .none
    public private(set) var applicationIndexNotice: String {
        get { applicationIndexNoticeMessage.rendered() }
        set { applicationIndexNoticeMessage = .verbatim(newValue) }
    }
    @Published public internal(set) var drafts: [UUID: AIDraftDocument] = [:]
    @Published public internal(set) var pendingCommandReviews: [PendingCommandReview] = []
    var activeCommandReviews: [UUID: PendingCommandReview] = [:]
    @Published public internal(set) var isClearingHistory = false
    @Published public internal(set) var isClearingUsage = false
    public var onHistoryRemoved: ((Set<UUID>, Set<UUID>) -> Void)?
    let sessionLimits: SessionRetentionPolicy
    var executionReservations: Set<UUID> = []
    var visibleDraftReferences: [UUID: UUID] = [:]
    var visibleTaskReferences: [UUID: UUID] = [:]
    var draftOrder: [UUID] = []
    var mutatingSession = false
    var historyGeneration: UInt64 = 0
    var usageHistoryGeneration: UInt64 = 0
    var usageSummaryGenerations: [UUID: UInt64] = [:]
    var invalidatedUsageRuns: Set<UUID> = []
    let usageMetadataStore: AIUsageMetadataStore
    var receiptMaintenanceTask: Task<Void, Never>?
    public var onDismiss: ((Bool) -> Void)?
    public var onOpenSettings: ((SettingsPane?) -> Void)?
    public var onOpenShortcutSettings: ((CommandItem) -> Void)?
    public var onOpenWorkspace: ((WorkspaceRoute) -> Void)?
    public var onOpenClipboard: (() -> Void)?
    public var onAIAction: ((AIDraftDocument, ExecutionCaller) -> Void)?
    public var onCaptureRequested: (() -> Void)?
    public var onReviewCommand: ((SavedCommand) -> Void)?
    public var onLanguageChanged: (() -> Void)?
    public var onAppearanceChanged: (() -> Void)?
    /// 同步提交候选注册；失败必须保留旧方案，已保存方案恢复失败必须停用全部并报告状态。
    public var onShortcutConfigurationChanged: ((AppConfiguration) throws -> Void)?
    public var onShortcutRecordingChanged: ((Bool) -> Void)?
    public func reportShortcutRegistrationFailure() {
        shortcutsUnavailable = true
        let message = noticeKey("Shortcut could not be registered. It may be used by macOS or another application.")
        settingsNoticeMessage = message; launcherNoticeMessage = message
    }
    public let desktop: DesktopService
    let windowLayouts = WindowLayoutController()
    public var target: TargetSnapshot?
    public let clipboardStore: ClipboardStore
    let monitor: ClipboardMonitor
    let processRunner = ProcessRunner()
    let terminalHandoff: TerminalHandoffAdapter
    let invocationStore: InvocationStore
    let aiInvocationStore: InvocationStore
    let agentToolStore: InvocationStore
    let scheduleLedger: ScheduleLedger
    @Published public internal(set) var schedules: [ScheduleSnapshot] = []
    @Published public internal(set) var scheduleBusy = false
    var scheduleTimer: Task<Void,Never>?
    var scheduleSuspended: Set<UUID> = []
    var scheduledRuns: [UUID:UUID] = [:]
    let activityLedger: ActivityLedger
    @Published public internal(set) var activityReport: ActivityReport?
    @Published public internal(set) var activityChanging = false
    var activityGeneration: UInt64 = 0
    var activityIsClearing = false
    var taskActivity: [UUID: (String, ActivityCategory)] = [:]
    @Published public internal(set) var workflowCheckpoints: [UUID: WorkflowCheckpoint] = [:]
    @Published public internal(set) var pendingWorkflowInputs: [PendingWorkflowInput] = []
    var workflowInputContinuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    @Published public internal(set) var mcpCatalogs: [UUID: MCPToolCatalog] = [:]
    @Published public internal(set) var mcpResources: [UUID: MCPResourceCatalog] = [:]
    @Published public internal(set) var mcpPrompts: [UUID: MCPPromptCatalog] = [:]
    @Published public internal(set) var mcpBusy = false
    @Published public internal(set) var mcpSettingsChanging = false
    @Published public internal(set) var mcpCapabilities: [UUID: Set<String>] = [:]
    var mcpSessionDisabled: Set<UUID> = []
    var mcpClients: [UUID: MCPHTTPClient] = [:]
    var mcpRunClients: [UUID: [MCPHTTPClient]] = [:]
    var mcpRunScopes: [UUID: Set<UUID>] = [:]
    var mcpGeneration = UUID()
    var mcpConnectionTask: Task<Void,Never>?
    var timedOutTaskIDs: Set<UUID> = []
    var pausedAgentIDs: Set<UUID> = []
    var agentRunDefinitions: [UUID: AgentDefinition] = [:]
    @Published public internal(set) var pendingApprovals: [AgentToolApproval] = []
    var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    let directory: URL
    var taskHandles: [UUID: Task<Void, Never>] = [:]
    var aiTaskIDs: Set<UUID> = []
    var cancelledTaskIDs: Set<UUID> = []
    var resultTargets: [UUID: TargetSnapshot] = [:]
    var proposalRequests: [UUID: UUID] = [:]
    private var windowGeneration = UUID()
    private var launcherReplyGeneration = UUID()
    private var applicationItems: [CommandItem] = []
    public let allowContextCapture: Bool
    let clipboardWriter: @MainActor (String) -> Void
    let clipboardChangeCount: @MainActor () -> Int
    private let clipboardReader: @MainActor () -> String?
    private let applicationLauncher: @MainActor (CommandItem) async throws -> PreparedApplicationLaunch
    let credentialReader: @MainActor (String) throws -> String?
    let credentialWriter: @MainActor (String, String) throws -> Void
    let configurationWriter: @MainActor (Data, URL) throws -> Void
    private let languageApplier: @MainActor (String) -> Void
    // 剪贴板是全局资源；不同草稿的迟到结果也不能覆盖较新的复制请求。
    var latestAutoCopyRunID: UUID?

    public init(dataDirectory: URL? = nil, allowContextCapture: Bool = true,
                clipboardWriter: @escaping @MainActor (String) -> Void = { ClipboardMonitor.copy($0) },
                clipboardChangeCount: @escaping @MainActor () -> Int = { NSPasteboard.general.changeCount },
                clipboardReader: @escaping @MainActor () -> String? = { ClipboardMonitor.explicitTextInput() },
                credentialReader: @escaping @MainActor (String) throws -> String? = { try CredentialStore.load(account: $0) },
                credentialWriter: @escaping @MainActor (String, String) throws -> Void = { try CredentialStore.save($0, account: $1) },
                configurationWriter: @escaping @MainActor (Data, URL) throws -> Void = { try PrivateFiles.write($0, to: $1) },
                terminalHandoff: TerminalHandoffAdapter = TerminalHandoffAdapter(),
                applicationCatalog: ApplicationCatalog? = nil,
                applicationLauncher: (@MainActor (CommandItem) async throws -> PreparedApplicationLaunch)? = nil,
                sessionLimits: SessionRetentionPolicy = SessionRetentionPolicy(),
                clipboardCaptureSource: (any ClipboardCaptureSource)? = nil,
                languageApplier: @escaping @MainActor (String) -> Void = { KDLocalizer.setLanguage($0) }) throws {
        self.sessionLimits = sessionLimits
        let desktop = DesktopService(applicationCatalog: applicationCatalog ?? ApplicationCatalog())
        self.desktop = desktop
        self.applicationLauncher = applicationLauncher ?? { try await desktop.launchApplication($0) }
        self.allowContextCapture = allowContextCapture
        self.clipboardWriter = clipboardWriter
        self.clipboardChangeCount = clipboardChangeCount
        self.clipboardReader = clipboardReader
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
        self.configurationWriter = configurationWriter
        self.languageApplier = languageApplier
        self.terminalHandoff = terminalHandoff
        directory = try dataDirectory ?? PrivateFiles.applicationDirectory()
        usageMetadataStore = AIUsageMetadataStore(directory: directory.appendingPathComponent("usage"))
        let url = directory.appendingPathComponent("configuration.json")
        var statisticsEnabled = false
        if FileManager.default.fileExists(atPath: url.path) {
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
            guard decoded.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
            configuration = decoded
            statisticsEnabled = decoded.activityEnabled
        } else {
            var c = AppConfiguration()
            c.aiActions = AppConfiguration.builtins
            configuration = c
        }
        clipboardStore = try ClipboardStore(url: directory.appendingPathComponent("clipboard.sqlite"))
        monitor = ClipboardMonitor(store: clipboardStore, source: clipboardCaptureSource)
        invocationStore = try InvocationStore(directory: directory.appendingPathComponent("invocations"))
        aiInvocationStore = try InvocationStore(directory: directory.appendingPathComponent("ai-invocations"))
        agentToolStore = try InvocationStore(directory: directory.appendingPathComponent("agent-tool-invocations"))
        let scheduler = try ScheduleLedger(directory:directory.appendingPathComponent("schedules"),now:Date())
        scheduleLedger = scheduler; _schedules = Published(initialValue:scheduler.initialSnapshots)
        do { activityLedger = try ActivityLedger(directory:directory.appendingPathComponent("activity"),enabled:statisticsEnabled) }
        catch {
            activityLedger = try ActivityLedger(persistence:.init(load:{nil},save:{_ in throw ActivityError.invalidStorage}))
            configuration.activityEnabled = false
        }
        languageApplier(configuration.language)
        monitor.enabled = allowContextCapture && configuration.clipboardEnabled
        monitor.excludedApplications = Set(configuration.clipboardExclusions)
        monitor.onChange = { [weak self] in self?.refreshClipboard() }
        monitor.onFailure = { [weak self] in self?.workspaceNoticeMessage = noticeKey("Clipboard storage failed") }
        monitor.onCaptureIssue = { [weak self] in self?.clipboardCaptureIssue = $0 }
        monitor.start()
        desktop.applicationCatalog.onChange = { [weak self] items in
            guard let self, !self.isShuttingDown else { return }
            self.applicationItems = items; self.applicationIndexNoticeMessage = .none; self.rebuildCatalog()
        }
        desktop.applicationCatalog.onFailure = { [weak self] in self?.applicationIndexNoticeMessage = noticeKey("The application list may be out of date. Refresh it and try again.") }
        rebuildCatalog() // 首帧先提供内置能力，不等待磁盘索引或回执恢复。
        desktop.applicationCatalog.start(observing: false)
        let restoreGeneration = historyGeneration
        Task { [weak self] in
            guard let self else { return }
            await usageMetadataStore.setReportHandler { [weak self] report in
                Task { @MainActor [weak self] in self?.handleUsageMaintenance(report) }
            }
            guard !isShuttingDown else { return }
            await usageMetadataStore.start()
            let cli = await invocationStore.list()
            guard !isShuttingDown, historyGeneration == restoreGeneration else { return }
            let ai = await aiInvocationStore.list()
            guard !isShuttingDown, historyGeneration == restoreGeneration else { return }
            restoreHistorySnapshot(cli: cli, ai: ai, generation: restoreGeneration)
            await invocationStore.acknowledgeRecovery(); await aiInvocationStore.acknowledgeRecovery()
            await agentToolStore.acknowledgeRecovery()
            await maintainTaskHistory()
            guard !isShuttingDown else { return }
            guard !isShuttingDown else { return }; rebuildCatalog()
        }
        startSchedules()
        startReceiptMaintenance() // 恢复快照过时不能取消每日保留维护。
    }
    public func shutdown() {
        isShuttingDown = true; monitor.stop(); desktop.applicationCatalog.stop()
        windowLayouts.close()
        scheduleTimer?.cancel()
        mcpConnectionTask?.cancel()
        receiptMaintenanceTask?.cancel(); receiptMaintenanceTask = nil
        let usage = usageMetadataStore; Task { await usage.stop() }
        // 退出围栏与现有工作的取消同步生效，不能等异步终止回调开始后才取消网络。
        for id in Array(taskHandles.keys) { cancelTask(id) }
    }
    public func shutdownAndWait() async {
        shutdown(); let handles = taskHandles
        for handle in handles.values { await handle.value }
        await scheduleTimer?.value
        await mcpConnectionTask?.value
        let clients = Array(mcpClients.values) + mcpRunClients.values.flatMap{$0}
        for client in clients { await client.invalidate() }
        mcpClients.removeAll(); mcpRunClients.removeAll(); mcpRunScopes.removeAll()
        await usageMetadataStore.stop()
    }
    public func startApplicationUpdates() { guard !isShuttingDown else { return }; desktop.applicationCatalog.start() }
    public func refreshApplications() { guard !isShuttingDown else { return }; desktop.applicationCatalog.refresh() }
    public func invalidateLauncherReplies() { launcherReplyGeneration = UUID() }
    public func prepareLauncher(target: TargetSnapshot?) { invalidateLauncherReplies(); self.target = target; desktop.applicationCatalog.refreshIfStale(); refreshWindows() }
    public func refreshWindows() {
        guard allowContextCapture else { rebuildCatalog(); return }
        windowGeneration = UUID(); let current = windowGeneration
        Task { [weak self] in
            guard let self else { return }
            let windows = await desktop.windows()
            guard windowGeneration == current else { return }
            catalog = applicationItems + windows + commandItems()
        }
    }
    private func commandItems() -> [CommandItem] {
        let saved = configuration.savedCommands.map { CommandItem(id: "command." + $0.id.uuidString, title: $0.name, subtitle: $0.executable, kind: .command, payload: $0.id.uuidString) }
        let ai = configuration.aiActions.map { CommandItem(id: "ai." + $0.id.uuidString, title: $0.displayName, subtitle: L("AI action"), kind: .ai, payload: $0.id.uuidString) }
        let builtins = [("clipboard", L("Clipboard history")), ("tasks", L("Running tasks")), ("commands", L("Saved commands")), ("ai", L("AI workspace")), ("agent", L("Agent workspace")), ("settings", L("Settings"))].map { CommandItem(id: "utility." + $0.0, title: $0.1, kind: .utility, payload: $0.0) }
        let layouts = WindowLayout.allCases.map { layout in
            CommandItem(id: "utility.window-layout." + layout.rawValue, title: L(layout.titleKey), subtitle: L("Original window"), keywords: ["window", "layout", "窗口", "布局"], kind: .utility, payload: "window-layout." + layout.rawValue)
        }
        let additional = [("activity",L("Usage insights")),("workflows",L("Workflows")),("tools",L("Tools")),("capture",L("Capture a region"))].map { CommandItem(id:"utility."+$0.0,title:$0.1,kind:.utility,payload:$0.0) }
        let workflows = configuration.workflows.map { CommandItem(id:"workflow."+$0.id.uuidString,title:$0.name,subtitle:L("Workflow"),kind:.utility,payload:"workflow."+$0.id.uuidString) }
        let snippets = configuration.snippets.map { CommandItem(id:"snippet."+$0.id.uuidString,title:$0.name,subtitle:L("Snippet"),kind:.utility,payload:"snippet."+$0.id.uuidString) }
        let web = configuration.webActions.map { CommandItem(id:"web."+$0.id.uuidString,title:$0.name,subtitle:L("URL action"),kind:.utility,payload:"web."+$0.id.uuidString) }
        let collections = configuration.collections.map { CommandItem(id:"collection."+$0.id.uuidString,title:$0.name,subtitle:L("Command collection"),kind:.utility,payload:"collection."+$0.id.uuidString) }
        return saved + ai + builtins + layouts + additional + workflows + snippets + web + collections
    }
    private func rebuildCatalog() { catalog = catalog.filter { $0.kind == .window } + applicationItems + commandItems() }
    public func execute(_ item: CommandItem, caller: ExecutionCaller = .user) {
        guard !isShuttingDown else { launcherNoticeMessage = noticeKey("KeyDock is quitting. No new action was started."); return }
        invalidateLauncherReplies()
        configuration.preferences.recent[item.id] = Date(); save()
        switch item.kind {
        case .application:
            do { try authorizeHostItem(item, caller: caller) } catch { showError(error); return }
            let replyGeneration = launcherReplyGeneration, actionStarted = Date()
            Task {
                do {
                    let launch = try await applicationLauncher(item)
                    guard !isShuttingDown, launcherReplyGeneration == replyGeneration else { return }
                    guard launch.activate() else {
                        recordDirectActivity(commandID:item.id,category:.application,outcome:.failed,startedAt:actionStarted)
                        launcherNoticeMessage = noticeKey("The application opened, but macOS could not bring it to the front.")
                        return
                    }
                    recordDirectActivity(commandID:item.id,category:.application,outcome:.succeeded,startedAt:actionStarted)
                    onDismiss?(false)
                }
                catch {
                    guard !isShuttingDown else { return }
                    recordDirectActivity(commandID:item.id,category:.application,outcome:.failed,startedAt:actionStarted)
                    refreshApplications()
                    guard launcherReplyGeneration == replyGeneration else { return }
                    launcherNoticeMessage = noticeKey("Application could not be opened. It may have moved or changed; refreshing the list.")
                }
            }
        case .window:
            do { try authorizeHostItem(item, caller: caller); try desktop.activateWindow(item.payload); recordDirectActivity(commandID:item.id,category:.window,outcome:.succeeded); onDismiss?(false) } catch { showError(error) }
        case .command:
            if let command = configuration.savedCommands.first(where: { $0.id.uuidString == item.payload }), runCommand(command, caller: caller, showWorkspace: false) != nil { onDismiss?(true) }
        case .ai:
            guard let action = configuration.aiActions.first(where: { $0.id.uuidString == item.payload }) else { return }
            do { try authorizeHostItem(item, caller: caller) } catch { showError(error); return }
            let draft = createDraft(actionID: action.id, target: target, caller: caller)
            guard ownsDraft(draft) else { return }
            onAIAction?(draft, caller)
        case .utility:
            do { try authorizeHostItem(item, caller: caller) } catch { showError(error); return }
            if item.payload.hasPrefix("web."), let id = UUID(uuidString:String(item.payload.dropFirst(4))), let action = configuration.webActions.first(where:{$0.id == id}) { if action.requiresQuery { onOpenWorkspace?(.web(id)) } else { openWebAction(id,caller:caller) }; return }
            if item.payload.hasPrefix("collection."),let id = UUID(uuidString:String(item.payload.dropFirst(11))) { onOpenWorkspace?(.collection(id)); return }
            if item.payload.hasPrefix("snippet."), let id = UUID(uuidString:String(item.payload.dropFirst(8))) { copySnippet(id,caller:caller); onDismiss?(true); return }
            if item.payload.hasPrefix("calculate.") { do { try copyAuthorizedText(String(item.payload.dropFirst(10)),caller:caller); onDismiss?(true) } catch { showError(error) }; return }
            if item.payload.hasPrefix("window-layout."), let layout = WindowLayout(rawValue: String(item.payload.dropFirst("window-layout.".count))) {
                guard allowContextCapture, let snapshot = target else { launcherNoticeMessage = noticeKey("No original window is available"); return }
                Task { [weak self] in
                    guard let self else { return }
                    do { try await windowLayouts.apply(layout, target: snapshot); recordDirectActivity(commandID:item.id,category:.window,outcome:.succeeded); if !isShuttingDown { onDismiss?(false) } }
                    catch { if !isShuttingDown { launcherNoticeMessage = noticeKey("Window layout could not be applied. Check permission, target and window size.") } }
                }
                return
            }
            if item.payload.hasPrefix("workflow."), let id = UUID(uuidString:String(item.payload.dropFirst("workflow.".count))), let workflow = configuration.workflows.first(where:{$0.id == id}) { _ = runWorkflow(workflow,input:""); return }
            switch item.payload {
            case "activity": onOpenWorkspace?(.activity)
            case "workflows": onOpenWorkspace?(.workflows)
            case "tools": onOpenWorkspace?(.tools)
            case "capture": onCaptureRequested?()
            case "settings": onOpenSettings?(nil)
            case "commands": onOpenSettings?(.commands)
            case "clipboard": onOpenClipboard?()
            case "agent": onOpenWorkspace?(.agent)
            case "ai": let draft = createDraft(); if ownsDraft(draft) { onOpenWorkspace?(.ai(draft.id)) }
            default: onOpenWorkspace?(.tasks(nil))
            }
        case .clipboard: break
        }
    }
    public func toggleFavorite(_ item: CommandItem) {
        if configuration.preferences.favorites.contains(item.id) { configuration.preferences.favorites.remove(item.id) } else { configuration.preferences.favorites.insert(item.id) }
        save()
    }
    public func setAlias(_ alias: String, for id: String) { configuration.preferences.aliases[id] = alias; save() }
    public func save() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try configurationWriter(encoder.encode(configuration), directory.appendingPathComponent("configuration.json"))
            applyConfigurationEffects()
        } catch { settingsNoticeMessage = noticeKey("Configuration could not be saved") }
    }
    func applyConfigurationEffects() {
        monitor.excludedApplications = Set(configuration.clipboardExclusions)
        monitor.enabled = !isShuttingDown && allowContextCapture && configuration.clipboardEnabled
        clipboardPauseNeedsPersistence = false
        languageApplier(configuration.language); rebuildCatalog()
    }
    @discardableResult public func setClipboardRecording(_ enabled: Bool) -> Bool {
        guard allowContextCapture, !isShuttingDown else { return false }
        var next = configuration; next.clipboardEnabled = enabled
        if !enabled { monitor.enabled = false; configuration.clipboardEnabled = false }
        guard commitSettingsConfiguration(next) else {
            monitor.enabled = false; configuration.clipboardEnabled = false; clipboardPauseNeedsPersistence = true
            return false
        }
        return true
    }
    @discardableResult public func saveClipboardExclusions(_ applications: [String]) -> Bool {
        guard !isShuttingDown else { return false }
        monitor.enabled = false
        var next = configuration; next.clipboardExclusions = applications
        guard commitSettingsConfiguration(next) else {
            configuration.clipboardEnabled = false; clipboardPauseNeedsPersistence = true
            return false
        }
        return true
    }
    @discardableResult public func setLanguage(_ language: String) -> Bool {
        guard ["system", "en", "zh-Hans"].contains(language) else { return false }
        var next = configuration; next.language = language
        guard commitSettingsConfiguration(next) else { return false }
        onLanguageChanged?(); return true
    }
    @discardableResult public func setAppearance(_ appearance: String) -> Bool {
        guard ["system", "light", "dark"].contains(appearance) else { return false }
        var next = configuration; next.appearance = appearance
        guard commitSettingsConfiguration(next) else { return false }
        onAppearanceChanged?(); return true
    }
    /// 各窗口按自己的查询重读；不把整库正文发布到 MainActor。
    public func refreshClipboard() { clipboardRevision &+= 1 }
    public func requestAccessibility() { guard allowContextCapture else { settingsNoticeMessage = noticeKey("Context capture is disabled in isolated smoke mode"); return }; desktop.requestAccessibility() }
    public func saveAPIConfiguration(endpoint: String, modelName: String, localHTTP: Bool, tokenParameter: String, apiKey: String) -> Bool {
        guard allowContextCapture || apiKey.isEmpty else {
            settingsNoticeMessage = noticeKey("API keys cannot be stored in this isolated preview. Use a regular build to save a key.")
            return false
        }
        do {
            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AIProviderError.invalidConfiguration }
            try AIProviderConfiguration(endpoint: url, model: modelName, allowsLocalHTTP: localHTTP).validate()
            var next = configuration
            next.endpoint = url.absoluteString; next.model = modelName; next.localHTTP = localHTTP; next.tokenLimitParameter = tokenParameter
            try persistAPIConfiguration(next, apiKey: apiKey)
            configuration = next; applyConfigurationEffects(); settingsNoticeMessage = noticeKey("API configuration saved"); return true
        } catch AIProviderError.invalidConfiguration { settingsNoticeMessage = noticeKey("Configure a valid API endpoint and model in Settings") }
        catch APIConfigurationPersistenceError.rollbackIncomplete { settingsNoticeMessage = noticeKey("API configuration could not be saved and rollback was incomplete. Check the saved endpoint and API key before retrying.") }
        catch { settingsNoticeMessage = noticeKey("API configuration could not be saved; active settings were preserved") }
        return false
    }
    public func credentialExists() -> Bool { guard allowContextCapture else { return false }; return (try? credentialReader(configuration.endpoint)) != nil }
    public func removeCredential() { guard allowContextCapture else { return }; do { try credentialWriter("", configuration.endpoint) } catch { settingsNoticeMessage = noticeKey("Keychain operation failed") } }
    @discardableResult public func saveCommand(_ command: SavedCommand) -> Bool {
        do { try command.validate() }
        catch { settingsNoticeMessage = noticeKey("Check name, absolute paths, arguments, environment and timeout"); return false }
        var next = configuration
        if let i = next.savedCommands.firstIndex(where: { $0.id == command.id }) { next.savedCommands[i] = command } else { next.savedCommands.append(command) }
        return commitSettingsConfiguration(next)
    }
    @discardableResult public func saveAction(_ action: AIActionPreset) -> Bool {
        var next = configuration
        if let i = next.aiActions.firstIndex(where: { $0.id == action.id }) { next.aiActions[i] = action } else { next.aiActions.append(action) }
        return commitShortcutConfiguration(next)
    }
    public func createDraft(actionID: UUID? = nil, input: String? = nil, target: TargetSnapshot? = nil, source: AIDraftSource? = nil, caller: ExecutionCaller = .user) -> AIDraftDocument {
        let action = configuration.aiActions.first { $0.id == actionID } ?? configuration.aiActions.first
        var value = input ?? "", original: TargetSnapshot?
        var origin = source ?? .manual
        var noticeMessage: LocalizedNotice = .none
        if input == nil, let action {
            switch action.input {
            case .selection: value = target?.selectedText ?? ""; original = target; origin = .selection
            case .clipboard:
                origin = .clipboard
                if allowContextCapture {
                    do { value = try authorizedClipboardInput(caller: caller) ?? ""; if value.isEmpty { noticeMessage = noticeKey("No clipboard text is available. Enter text manually.") } }
                    catch { noticeMessage = errorNotice(error) }
                } else { noticeMessage = noticeKey("Context capture is disabled in isolated smoke mode") }
            case .manual: break
            }
        }
        if original?.selectedTextExceedsLimit == true { noticeMessage = noticeKey("Input is too long. Split it into smaller parts; nothing was sent.") }
        let draft = AIDraftDocument(input: value, actionID: action?.id, target: original, source: origin)
        if draft.isDiscarded { launcherNoticeMessage = draft.noticeMessage; workspaceNoticeMessage = draft.noticeMessage; return draft }
        draft.noticeMessage = noticeMessage
        _ = registerDraft(draft)
        return draft
    }
    private func authorizedClipboardInput(caller: ExecutionCaller) throws -> String? {
        try authorizeHostAction(id: "clipboard.input", operation: .readClipboard, resource: "general|\(clipboardChangeCount())", availableContext: [.clipboard], caller: caller)
        return clipboardReader()
    }
    public func useClipboardInput(_ draft: AIDraftDocument) {
        guard ownsDraft(draft), !isClearingHistory else { return }
        guard allowContextCapture else { draft.noticeMessage = noticeKey("Context capture is disabled in isolated smoke mode"); return }
        do {
            guard let text = try authorizedClipboardInput(caller: .user), !text.isEmpty else { draft.noticeMessage = noticeKey("No clipboard text is available. Enter text manually."); return }
            draft.useClipboard(text)
        } catch { draft.noticeMessage = errorNotice(error) }
    }
    public func copyResult(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        guard !task.output.isEmpty else { resultNotice(noticeKey("No output"), id: id); return }
        do { try copyAuthorizedText(task.output) } catch { resultError(error, id: id) }
    }
    public func copyClipboardText(_ text: String) {
        do { try copyAuthorizedText(text); recordDirectActivity(commandID:"clipboard.copy",category:.clipboard,outcome:.succeeded) } catch { workspaceNoticeMessage = errorNotice(error) }
    }
    func copyAuthorizedText(_ text: String, caller: ExecutionCaller = .user) throws {
        try authorizeHostAction(id: "result.copy", operation: .copyText, resource: "general|" + fingerprint(text), caller: caller)
        latestAutoCopyRunID = nil
        clipboardWriter(text)
    }
    public func canReplaceResult(_ id: UUID) -> Bool {
        guard resultTargets[id] != nil, let task = tasks.first(where: { $0.id == id }) else { return false }
        return task.status == .completed && !task.outputIsIncomplete
    }
    public func replaceResult(_ id: UUID) {
        guard canReplaceResult(id), let original = resultTargets[id], let task = tasks.first(where: { $0.id == id }) else { resultNotice(noticeKey("Original selection is unavailable"), id: id); return }
        do {
            let context: Set<CommandContextRequirement> = original.selectedText == nil ? [] : [.selection]
            try authorizeHostAction(id: "selection.replace", operation: .replaceSelection,
                resource: "\(original.pid).\(original.launchDate?.timeIntervalSince1970 ?? 0).\(original.selectedText.map(fingerprint) ?? "")|" + fingerprint(task.output), availableContext: context)
            try desktop.replaceSelection(task.output, target: original); onDismiss?(false)
        } catch { resultError(error, id: id) }
    }
    private func resultNotice(_ text: LocalizedNotice, id: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].noticeMessage = text; if let draftID = tasks[index].draftID { drafts[draftID]?.noticeMessage = text } }
    }
    private func resultError(_ error: Error, id: UUID) { resultNotice(errorNotice(error), id: id) }
    public func showError(_ error: Error) {
        launcherNoticeMessage = errorNotice(error)
    }
    private func errorNotice(_ error: Error) -> LocalizedNotice {
        switch error {
        case WorkbenchLifecycleError.shuttingDown: noticeKey("KeyDock is quitting. No new action was started.")
        case HostDescriptorPolicyError.unavailable(let reasonKey): noticeKey(reasonKey)
        case HostDescriptorPolicyError.missingContext: noticeKey("Original selection is unavailable")
        case DesktopError.accessibilityRequired: noticeKey("Accessibility permission is required")
        case DesktopError.windowActivationFailed: noticeKey("macOS could not bring this window to the front. Try selecting it again.")
        case DesktopError.targetExpired: noticeKey("Original target changed; no text was replaced")
        case DesktopError.selectionUnavailable: noticeKey("Original selection is unavailable")
        case DesktopError.replacementUnsupported: noticeKey("This application does not support selection replacement; copy the result instead")
        default: noticeKey("Operation failed")
        }
    }
    public func shortcut(for id: String) -> HotkeyBinding? {
        if id.hasPrefix("ai."), let action = configuration.aiActions.first(where: { "ai." + $0.id.uuidString == id }) { return action.shortcut }; return configuration.commandShortcuts[id]
    }
    @discardableResult public func setShortcut(_ binding: HotkeyBinding?, for id: String) -> Bool {
        var next = configuration
        if id.hasPrefix("ai."), let i = next.aiActions.firstIndex(where: { "ai." + $0.id.uuidString == id }) { next.aiActions[i].shortcut = binding; next.commandShortcuts[id] = nil }
        else { next.commandShortcuts[id] = binding }
        return commitShortcutConfiguration(next)
    }
    public var directShortcuts: [(String, HotkeyBinding)] {
        ShortcutPlan.entries(configuration).compactMap { entry in entry.commandID.map { ($0, entry.binding) } }
    }
    public func performCommand(id: String) { if let item = catalog.first(where: { $0.id == id }) { execute(item, caller: .shortcut) } else { launcherNoticeMessage = noticeKey("The shortcut target is no longer available") } }
}
