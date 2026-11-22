import AppKit
import SwiftUI
import CommandCore
import ExecutionCore
import AICore
import MacAdapters
import KeyDockUI

/// 唯一业务 Store：共享服务、配置、任务与文档；窗口导航、搜索和编辑状态由各 Session 拥有。
@MainActor public final class WorkbenchModel: ObservableObject {
    @Published public var configuration: AppConfiguration
    @Published public private(set) var catalog: [CommandItem] = []
    @Published public var clipboardEntries: [ClipboardEntry] = []
    @Published public var tasks: [RunningTaskItem] = []
    @Published public var launcherNotice = ""
    @Published public var settingsNotice = ""
    @Published public var workspaceNotice = ""
    @Published public private(set) var drafts: [UUID: AIDraftDocument] = [:]
    public var onDismiss: ((Bool) -> Void)?
    public var onOpenSettings: ((SettingsPane?) -> Void)?
    public var onOpenWorkspace: ((WorkspaceRoute) -> Void)?
    public var onAIAction: ((AIDraftDocument, ExecutionCaller) -> Void)?
    public var onReviewCommand: ((SavedCommand) -> Void)?
    public var onLanguageChanged: (() -> Void)?
    public var onAppearanceChanged: (() -> Void)?
    public var onShortcutConfigurationChanged: (() -> Void)?
    public var onShortcutRecordingChanged: ((Bool) -> Void)?
    public let desktop = DesktopService()
    public var target: TargetSnapshot?
    public let clipboardStore: ClipboardStore
    private let monitor: ClipboardMonitor
    let processRunner = ProcessRunner()
    let invocationStore: InvocationStore
    let directory: URL
    var taskHandles: [UUID: Task<Void, Never>] = [:]
    var aiTaskIDs: Set<UUID> = []
    var cancelledTaskIDs: Set<UUID> = []
    var resultTargets: [UUID: TargetSnapshot] = [:]
    var proposalRequests: [UUID: UUID] = [:]
    private var clipboardTask: Task<Void, Never>?
    private var windowGeneration = UUID()
    private var applicationItems: [CommandItem] = []
    public let allowContextCapture: Bool

    public init(dataDirectory: URL? = nil, allowContextCapture: Bool = true) throws {
        self.allowContextCapture = allowContextCapture
        directory = try dataDirectory ?? PrivateFiles.applicationDirectory()
        let url = directory.appendingPathComponent("configuration.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
            guard decoded.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
            configuration = decoded
        } else {
            var c = AppConfiguration()
            c.aiActions = AppConfiguration.builtins
            configuration = c
        }
        clipboardStore = try ClipboardStore(url: directory.appendingPathComponent("clipboard.sqlite"))
        monitor = ClipboardMonitor(store: clipboardStore)
        invocationStore = try InvocationStore(directory: directory.appendingPathComponent("invocations"))
        KDLocalizer.setLanguage(configuration.language)
        monitor.enabled = allowContextCapture && configuration.clipboardEnabled
        monitor.excludedApplications = Set(configuration.clipboardExclusions)
        monitor.onChange = { [weak self] in self?.refreshClipboard() }
        monitor.onFailure = { [weak self] in self?.workspaceNotice = L("Clipboard storage failed") }
        monitor.start()
        Task { [weak self] in
            guard let self else { return }
            for receipt in await invocationStore.list() { restoreReceipt(receipt) }
            applicationItems = await desktop.applications(); rebuildCatalog()
        }
    }
    public func shutdown() { monitor.stop() }
    public func shutdownAndWait() async {
        monitor.stop(); let handles = taskHandles
        for id in handles.keys { cancelTask(id) }
        for handle in handles.values { await handle.value }
    }
    public func prepareLauncher(target: TargetSnapshot?) { self.target = target; refreshWindows() }
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
        let builtins = [("clipboard", L("Clipboard history")), ("tasks", L("Running tasks")), ("commands", L("Saved commands")), ("ai", L("AI workspace")), ("settings", L("Settings"))].map { CommandItem(id: "utility." + $0.0, title: $0.1, kind: .utility, payload: $0.0) }
        return saved + ai + builtins
    }
    private func rebuildCatalog() { catalog = catalog.filter { $0.kind == .window } + applicationItems + commandItems() }
    public func execute(_ item: CommandItem, caller: ExecutionCaller = .user) {
        do { _ = try descriptor(for: item) } catch { showError(error); return }
        configuration.preferences.recent[item.id] = Date(); save()
        switch item.kind {
        case .application:
            do { try authorizeHostAction(id: item.id, effect: .activateApplication, resource: item.payload, caller: caller) } catch { showError(error); return }
            onDismiss?(false)
            Task { do { try await desktop.launchApplication(path: item.payload) } catch { launcherNotice = L("Application could not be opened") } }
        case .window:
            do { try authorizeHostAction(id: item.id, effect: .activateWindow, resource: item.payload, caller: caller); try desktop.activateWindow(item.payload); onDismiss?(false) } catch { showError(error) }
        case .command:
            if let command = configuration.savedCommands.first(where: { $0.id.uuidString == item.payload }) { runCommand(command, caller: caller, showWorkspace: false); onDismiss?(true) }
        case .ai:
            guard let action = configuration.aiActions.first(where: { $0.id.uuidString == item.payload }) else { return }
            let draft = createDraft(actionID: action.id, target: target)
            onAIAction?(draft, caller)
        case .utility:
            switch item.payload {
            case "settings": onOpenSettings?(nil)
            case "commands": onOpenSettings?(.commands)
            case "clipboard": onOpenWorkspace?(.clipboard)
            case "ai": onOpenWorkspace?(.ai(createDraft().id))
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
            try PrivateFiles.write(encoder.encode(configuration), to: directory.appendingPathComponent("configuration.json"))
            monitor.enabled = allowContextCapture && configuration.clipboardEnabled
            monitor.excludedApplications = Set(configuration.clipboardExclusions)
            KDLocalizer.setLanguage(configuration.language); rebuildCatalog()
        } catch { settingsNotice = L("Configuration could not be saved") }
    }
    public func setLanguage(_ language: String) { configuration.language = language; save(); onLanguageChanged?() }
    public func setAppearance(_ appearance: String) { configuration.appearance = appearance; save(); onAppearanceChanged?() }
    public func refreshClipboard(query: String = "") {
        clipboardTask?.cancel()
        clipboardTask = Task { [weak self] in
            guard let self else { return }
            do { let values = try await clipboardStore.entries(query: query); if !Task.isCancelled { clipboardEntries = values } }
            catch { workspaceNotice = L("Clipboard storage failed") }
        }
    }
    public func pin(_ entry: ClipboardEntry) { Task { do { try await clipboardStore.setPinned(id: entry.id, pinned: !entry.pinned); refreshClipboard() } catch { showError(error) } } }
    public func delete(_ entry: ClipboardEntry) { Task { do { try await clipboardStore.delete(id: entry.id); refreshClipboard() } catch { showError(error) } } }
    public func clearClipboard() { Task { do { try await clipboardStore.clear(); clipboardEntries = [] } catch { showError(error) } } }
    public func requestAccessibility() { desktop.requestAccessibility() }
    public func saveAPIConfiguration(endpoint: String, modelName: String, localHTTP: Bool, tokenParameter: String, apiKey: String) -> Bool {
        do {
            guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AIProviderError.invalidConfiguration }
            try AIProviderConfiguration(endpoint: url, model: modelName, allowsLocalHTTP: localHTTP).validate()
            if allowContextCapture && !apiKey.isEmpty { try CredentialStore.save(apiKey, account: url.absoluteString) }
            var next = configuration
            next.endpoint = url.absoluteString; next.model = modelName; next.localHTTP = localHTTP; next.tokenLimitParameter = tokenParameter
            try PrivateFiles.write(JSONEncoder().encode(next), to: directory.appendingPathComponent("configuration.json"))
            configuration = next; settingsNotice = L("API configuration saved"); return true
        } catch AIProviderError.invalidConfiguration { settingsNotice = L("Configure a valid API endpoint and model in Settings") }
        catch { settingsNotice = L("API configuration could not be saved; active settings were preserved") }
        return false
    }
    public func credentialExists() -> Bool { guard allowContextCapture else { return false }; return (try? CredentialStore.load(account: configuration.endpoint)) != nil }
    public func removeCredential() { guard allowContextCapture else { return }; do { try CredentialStore.save("", account: configuration.endpoint) } catch { settingsNotice = L("Keychain operation failed") } }
    public func saveCommand(_ command: SavedCommand) {
        if let i = configuration.savedCommands.firstIndex(where: { $0.id == command.id }) { configuration.savedCommands[i] = command } else { configuration.savedCommands.append(command) }; save()
    }
    public func saveAction(_ action: AIActionPreset) {
        if let i = configuration.aiActions.firstIndex(where: { $0.id == action.id }) { configuration.aiActions[i] = action } else { configuration.aiActions.append(action) }
        save(); onShortcutConfigurationChanged?()
    }
    public func createDraft(actionID: UUID? = nil, input: String? = nil, target: TargetSnapshot? = nil, source: AIDraftSource? = nil) -> AIDraftDocument {
        let action = configuration.aiActions.first { $0.id == actionID } ?? configuration.aiActions.first
        var value = input ?? "", original: TargetSnapshot?
        var origin = source ?? .manual
        if input == nil, let action {
            switch action.input {
            case .selection: value = target?.selectedText ?? ""; original = target; origin = .selection
            case .clipboard: origin = .clipboard; value = allowContextCapture ? (ClipboardMonitor.explicitTextInput() ?? "") : ""
            case .manual: break
            }
        }
        let draft = AIDraftDocument(input: value, actionID: action?.id, target: original, source: origin); drafts[draft.id] = draft; return draft
    }
    public func useClipboardInput(_ draft: AIDraftDocument) { guard allowContextCapture else { draft.notice = L("Context capture is disabled in isolated smoke mode"); return }; draft.useClipboard(ClipboardMonitor.explicitTextInput() ?? "") }
    public func copyResult(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        do { try authorizeHostAction(id: "result.copy", effect: .writeClipboard, resource: "general"); ClipboardMonitor.copy(task.output) } catch { resultError(error, id: id) }
    }
    public func canReplaceResult(_ id: UUID) -> Bool { resultTargets[id] != nil && tasks.first(where: { $0.id == id })?.status == .completed }
    public func replaceResult(_ id: UUID) {
        guard let original = resultTargets[id], let task = tasks.first(where: { $0.id == id }) else { resultNotice(L("Original selection is unavailable"), id: id); return }
        do { try authorizeHostAction(id: "selection.replace", effect: .replaceText, resource: "\(original.pid).\(original.launchDate?.timeIntervalSince1970 ?? 0).\(original.selectedText.map(fingerprint) ?? "")"); try desktop.replaceSelection(task.output, target: original); onDismiss?(false) } catch { resultError(error, id: id) }
    }
    private func resultNotice(_ text: String, id: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].notice = text; if let draftID = tasks[index].draftID { drafts[draftID]?.notice = text } }
    }
    private func resultError(_ error: Error, id: UUID) { resultNotice(errorText(error), id: id) }
    public func showError(_ error: Error) {
        launcherNotice = errorText(error)
    }
    private func errorText(_ error: Error) -> String {
        switch error {
        case DesktopError.accessibilityRequired: L("Accessibility permission is required")
        case DesktopError.targetExpired: L("Original target changed; no text was replaced")
        case DesktopError.selectionUnavailable: L("Original selection is unavailable")
        case DesktopError.replacementUnsupported: L("This application does not support selection replacement; copy the result instead")
        default: L("Operation failed")
        }
    }
    public func shortcut(for id: String) -> HotkeyBinding? {
        if id.hasPrefix("ai."), let action = configuration.aiActions.first(where: { "ai." + $0.id.uuidString == id }) { return action.shortcut }; return configuration.commandShortcuts[id]
    }
    public func setShortcut(_ binding: HotkeyBinding?, for id: String) {
        if id.hasPrefix("ai."), let i = configuration.aiActions.firstIndex(where: { "ai." + $0.id.uuidString == id }) { configuration.aiActions[i].shortcut = binding; configuration.commandShortcuts[id] = nil }
        else { configuration.commandShortcuts[id] = binding }
        save(); onShortcutConfigurationChanged?()
    }
    public var directShortcuts: [(String, HotkeyBinding)] {
        var values = configuration.commandShortcuts.filter { !$0.key.hasPrefix("ai.") }
        for action in configuration.aiActions { if let shortcut = action.shortcut { values["ai." + action.id.uuidString] = shortcut } }
        return values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    public func performCommand(id: String) { if let item = catalog.first(where: { $0.id == id }) { execute(item, caller: .shortcut) } else { launcherNotice = L("The shortcut target is no longer available") } }
}
