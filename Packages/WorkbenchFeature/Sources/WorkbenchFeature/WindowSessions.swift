import Foundation
import Combine
import CommandCore
import ExecutionCore
import MacAdapters

/// 当前缓存目录作为真实 Provider 接入统一查询链路，不再在 UI 旁路调用 rank。
private struct LauncherCatalogProvider: CommandProviding {
    let id = "keydock.catalog"
    let items: [CommandItem]
    func commands(matching query: String) async throws -> [CommandItem] {
        try Task.checkCancellation()
        return items
    }
}

@MainActor public final class LauncherSession: ObservableObject {
    @Published public var query = "" { didSet { if query != oldValue { store.invalidateLauncherReplies() }; search() } }
    @Published public var results: [CommandItem] = []
    @Published public var selectedID: String?
    @Published public private(set) var selectionScrollRequest = UUID()
    @Published public var focusRequest = UUID()
    @Published public var actionsVisible = false
    @Published public var contextCapturePending = false
    @Published public private(set) var queryRequest: QueryRequest?
    @Published public private(set) var resultBatch: ResultBatch?
    public var onExecute: ((CommandItem) -> Void)?
    @Published public var draft: AIDraftDocument? { didSet { updateVisibleReferences() } }
    private let visibilityOwner = UUID()
    private var visible = false
    private let store: WorkbenchModel
    private let coordinator = QueryCoordinator()
    private var generation: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    public init(store: WorkbenchModel) {
        self.store = store
        store.$catalog.sink { [weak self] _ in Task { @MainActor in self?.search() } }.store(in: &subscriptions)
        store.$configuration.sink { [weak self] _ in Task { @MainActor in self?.search() } }.store(in: &subscriptions)
    }
    public var selection: CommandItem? { results.first { $0.id == selectedID } }
    public func setVisible(_ value: Bool) { visible = value; updateVisibleReferences() }
    private func updateVisibleReferences() {
        if visible { store.setVisibleReferences(owner: visibilityOwner, draftID: draft?.id, taskID: nil) }
        else { store.releaseVisibleReferences(owner: visibilityOwner) }
    }
    public func removeHistory(draftIDs: Set<UUID>) { if let draft, draftIDs.contains(draft.id) { self.draft = nil } }
    public func reset() { draft = nil; query = ""; selectedID = nil; actionsVisible = false; focusRequest = UUID(); search() }
    public func search() {
        searchTask?.cancel(); generation &+= 1
        let request = QueryRequest(generation: generation, text: query, source: "keydock.launcher")
        queryRequest = request; resultBatch = nil
        let items = store.catalog.filter { !query.isEmpty || $0.kind != .window }
        let provider = LauncherCatalogProvider(items: items), preferences = store.configuration.preferences
        searchTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let stream = await coordinator.search(request: request, providers: [provider], preferences: preferences)
            for await batch in stream {
                guard !Task.isCancelled, queryRequest?.queryID == batch.queryID,
                      queryRequest?.generation == batch.generation else { return }
                // 初始空批次只是等待状态，不闪出“无结果”，也不使旧结果变成可执行的新结果。
                guard !batch.items.isEmpty || batch.isComplete else { continue }
                results = batch.items; resultBatch = batch
                if !results.contains(where: { $0.id == selectedID }) {
                    selectedID = results.first?.id; selectionScrollRequest = UUID()
                }
            }
        }
    }
    public func move(_ delta: Int) {
        let visible = results; guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[max(0, min(visible.count - 1, index + delta))].id
        selectionScrollRequest = UUID()
    }
    public func execute() {
        guard let request = queryRequest, let batch = resultBatch,
              request.queryID == batch.queryID, request.generation == batch.generation,
              let selection else { return }
        if let onExecute { onExecute(selection) } else { store.execute(selection) }
    }
}

@MainActor public final class SettingsSession: ObservableObject {
    @Published public var pane: SettingsPane = .general { didSet { UserDefaults.standard.set(pane.rawValue, forKey: panePreferenceKey); onPaneChanged?() } }
    private var panePreferenceKey = "KeyDock.SettingsPane"
    public var onPaneChanged: (() -> Void)?
    @Published public var editedCommandSourceRunID: UUID? {
        didSet { if let oldValue, oldValue != editedCommandSourceRunID { store?.finishCommandReview(oldValue) }; updateVisibleReferences() }
    }
    private weak var store: WorkbenchModel?
    private let visibilityOwner = UUID()
    private var visible = false
    @Published public var editedCommand: SavedCommand?
    @Published public var editedAction: AIActionPreset?
    @Published public var apiKey = ""
    @Published public var keyStored = false
    @Published public var endpoint = ""
    @Published public var modelName = ""
    @Published public var localHTTP = false
    @Published public var tokenParameter = "max_completion_tokens"
    @Published public var shortcutQuery = ""
    @Published public private(set) var shortcutTargetID: String?
    public func focusShortcut(_ item: CommandItem) {
        shortcutQuery = item.title; shortcutTargetID = item.id; pane = .shortcuts
    }
    public func editShortcutQuery(_ query: String) { shortcutTargetID = nil; shortcutQuery = query }
    public func shortcutItems(in catalog: [CommandItem], preferences: CommandPreferences) -> [CommandItem] {
        if let shortcutTargetID, let target = catalog.first(where: { $0.id == shortcutTargetID }) { return [target] }
        if !shortcutQuery.isEmpty { return Array(CommandSearch.rank(query: shortcutQuery, items: catalog, preferences: preferences).prefix(20)) }
        return catalog.filter { $0.kind == .ai || $0.kind == .command || preferences.favorites.contains($0.id) || store?.shortcut(for: $0.id) != nil }
    }
    public init(store: WorkbenchModel) {
        self.store = store
        panePreferenceKey = store.allowContextCapture ? "KeyDock.SettingsPane" : "KeyDock.Smoke.SettingsPane"
        pane = UserDefaults.standard.string(forKey: panePreferenceKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
        endpoint = store.configuration.endpoint; modelName = store.configuration.model
        localHTTP = store.configuration.localHTTP; tokenParameter = store.configuration.tokenLimitParameter
    }
    public func beginNewCommand() {
        guard store?.isShuttingDown == false, editedCommand == nil, editedAction == nil else { return }
        editedCommandSourceRunID = nil
        editedCommand = SavedCommand(name: "", executable: "/usr/bin/printf")
    }
    public func beginNewAction() {
        guard store?.isShuttingDown == false, editedCommand == nil, editedAction == nil else { return }
        editedAction = AIActionPreset(name: "", prompt: "")
    }
    public func setVisible(_ value: Bool) { visible = value; updateVisibleReferences() }
    private func updateVisibleReferences() {
        guard let store else { return }
        if visible { store.setVisibleReferences(owner: visibilityOwner, draftID: nil, taskID: editedCommandSourceRunID) }
        else { store.releaseVisibleReferences(owner: visibilityOwner) }
    }
    public func removeHistory(taskIDs: Set<UUID>) {
        if editedCommandSourceRunID.map(taskIDs.contains) == true { editedCommand = nil; editedCommandSourceRunID = nil }
    }
}

@MainActor public final class WorkspaceSession: ObservableObject {
    public enum Page: String, CaseIterable { case tasks, ai, clipboard }
    @Published public var page: Page = .tasks
    @Published public var selectedTaskID: UUID? { didSet { updateVisibleReferences() } }
    @Published public var draft: AIDraftDocument? { didSet { updateVisibleReferences() } }
    private weak var store: WorkbenchModel?
    private let visibilityOwner = UUID()
    private var visible = false
    public let clipboard = ClipboardBrowserSession()
    public var clipboardQuery: String {
        get { clipboard.query }
        set { clipboard.query = newValue }
    }
    private var clipboardChanges: AnyCancellable?
    public init() {
        clipboardChanges = clipboard.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    public func setVisible(_ value: Bool, in store: WorkbenchModel) { self.store = store; visible = value; updateVisibleReferences() }
    public func present(_ route: WorkspaceRoute? = nil, in store: WorkbenchModel) {
        setVisible(true, in: store)
        if let route { navigate(route, store: store) }
        else if page == .tasks && selectedTaskID == nil { navigate(.tasks(nil), store: store) }
    }
    private func updateVisibleReferences() {
        guard let store else { return }
        if visible { store.setVisibleReferences(owner: visibilityOwner, draftID: draft?.id, taskID: selectedTaskID) }
        else { store.releaseVisibleReferences(owner: visibilityOwner) }
    }
    public func removeHistory(taskIDs: Set<UUID>, draftIDs: Set<UUID>, in store: WorkbenchModel) {
        if let draft, draftIDs.contains(draft.id) { self.draft = nil }
        if selectedTaskID.map(taskIDs.contains) == true { selectedTaskID = store.tasks.first?.id }
    }
    public func navigate(_ route: WorkspaceRoute, store: WorkbenchModel) {
        switch route {
        case .tasks(let id): page = .tasks; if let id { selectedTaskID = id } else if selectedTaskID == nil { selectedTaskID = store.tasks.first?.id }
        case .ai(let id): page = .ai; draft = store.drafts[id]
        case .clipboard: page = .clipboard
        }
    }
    public func createDraft(in store: WorkbenchModel) {
        let next = store.createDraft()
        guard store.ownsDraft(next) else { return }
        draft = next; page = .ai
    }
    public func availableDrafts(in store: WorkbenchModel) -> [AIDraftDocument] {
        store.draftOrder.reversed().compactMap { store.drafts[$0] }.filter { store.ownsDraft($0) }
    }
}
