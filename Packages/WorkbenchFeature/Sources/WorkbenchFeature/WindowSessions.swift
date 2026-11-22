import Foundation
import Combine
import CommandCore
import ExecutionCore
import MacAdapters

@MainActor public final class LauncherSession: ObservableObject {
    @Published public var query = "" { didSet { search() } }
    @Published public var results: [CommandItem] = []
    @Published public var selectedID: String?
    @Published public var focusRequest = UUID()
    @Published public var actionsVisible = false
    @Published public var contextCapturePending = false
    public var onExecute: ((CommandItem) -> Void)?
    @Published public var draft: AIDraftDocument?
    private let store: WorkbenchModel
    private var generation = UUID()
    private var resultGeneration: UUID?
    private var searchTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    public init(store: WorkbenchModel) {
        self.store = store
        store.$catalog.sink { [weak self] _ in Task { @MainActor in self?.search() } }.store(in: &subscriptions)
        store.$configuration.sink { [weak self] _ in Task { @MainActor in self?.search() } }.store(in: &subscriptions)
    }
    public var selection: CommandItem? { results.first { $0.id == selectedID } }
    public func reset() { draft = nil; query = ""; selectedID = nil; actionsVisible = false; focusRequest = UUID(); search() }
    public func search() {
        searchTask?.cancel(); generation = UUID()
        let id = generation, q = query, items = store.catalog.filter { !query.isEmpty || $0.kind != .window }, prefs = store.configuration.preferences
        searchTask = Task { [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) { CommandSearch.rank(query: q, items: items, preferences: prefs) }.value
            guard let self, !Task.isCancelled, generation == id else { return }
            results = ranked; resultGeneration = id
            if !ranked.contains(where: { $0.id == selectedID }) { selectedID = ranked.first?.id }
        }
    }
    public func move(_ delta: Int) {
        let visible = results; guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[max(0, min(visible.count - 1, index + delta))].id
    }
    public func execute() { guard resultGeneration == generation, let selection else { return }; if let onExecute { onExecute(selection) } else { store.execute(selection) } }
}

@MainActor public final class SettingsSession: ObservableObject {
    @Published public var pane: SettingsPane = .general { didSet { UserDefaults.standard.set(pane.rawValue, forKey: panePreferenceKey); onPaneChanged?() } }
    private var panePreferenceKey = "KeyDock.SettingsPane"
    public var onPaneChanged: (() -> Void)?
    @Published public var pendingCommands: [SavedCommand] = []
    @Published public var editedCommand: SavedCommand?
    @Published public var editedAction: AIActionPreset?
    @Published public var apiKey = ""
    @Published public var keyStored = false
    @Published public var endpoint = ""
    @Published public var modelName = ""
    @Published public var localHTTP = false
    @Published public var tokenParameter = "max_completion_tokens"
    public init(store: WorkbenchModel) {
        panePreferenceKey = store.allowContextCapture ? "KeyDock.SettingsPane" : "KeyDock.Smoke.SettingsPane"
        pane = UserDefaults.standard.string(forKey: panePreferenceKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
        endpoint = store.configuration.endpoint; modelName = store.configuration.model
        localHTTP = store.configuration.localHTTP; tokenParameter = store.configuration.tokenLimitParameter
    }
}

@MainActor public final class WorkspaceSession: ObservableObject {
    public enum Page: String, CaseIterable { case tasks, ai, clipboard }
    @Published public var page: Page = .tasks
    @Published public var selectedTaskID: UUID?
    @Published public var draft: AIDraftDocument?
    @Published public var clipboardQuery = ""
    public init() {}
    public func navigate(_ route: WorkspaceRoute, store: WorkbenchModel) {
        switch route {
        case .tasks(let id): page = .tasks; if let id { selectedTaskID = id }
        case .ai(let id): page = .ai; draft = store.drafts[id]
        case .clipboard: page = .clipboard
        }
    }
}
