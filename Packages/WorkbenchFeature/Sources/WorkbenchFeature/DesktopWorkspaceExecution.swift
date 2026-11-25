import AppKit
import CommandCore
import ExecutionCore
import MacAdapters

extension WorkbenchModel {
    func desktopWorkspaceItem(_ value: SavedDesktopWorkspace) -> CommandItem {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let revision = fingerprint(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
        return .init(id: value.commandID, title: value.name, subtitle: L("Desktop workspace"), keywords: ["workspace", "desktop", "工作区", "桌面"], kind: .utility, payload: value.commandID, objectRevision: revision)
    }
    public func isDesktopWorkspace(_ item: CommandItem) -> Bool { item.payload.hasPrefix("desktop-workspace.") }
    public func performDesktopWorkspaceShortcut(id: String) {
        guard let item = catalog.first(where: { $0.id == id && isDesktopWorkspace($0) }) else {
            let notice = noticeKey("The desktop workspace is unavailable or changed. Reopen it before applying.")
            launcherNoticeMessage = notice; settingsNoticeMessage = notice
            onOpenSettings?(.desktopWorkspaces); return
        }
        onDesktopAction?(item, .shortcut)
    }
    /// 同步撤销，真实worker仍由handle等待；新调用只能在它们收口后开始。
    public func cancelDesktopWorkspaceRuns() {
        for (id, run) in desktopWorkspaceGroups { run.group.revoke(); taskHandles[id]?.cancel() }
    }
    func cancelDesktopWorkspaceRuns(definitionID: UUID) {
        for (id, run) in desktopWorkspaceGroups where run.definitionID == definitionID { run.group.revoke(); taskHandles[id]?.cancel() }
    }
    @discardableResult public func runDesktopWorkspace(_ item: CommandItem, source: TargetIdentity?, invocationDisplayID: String?, caller: ExecutionCaller,
                                                      didFocus: @escaping @MainActor () -> Void = {}) -> UUID? {
        guard !isShuttingDown, allowContextCapture, let source, source.launchDate != nil,
              let definition = desktopWorkspaces.first(where: { $0.commandID == item.id }), desktopWorkspaceItem(definition) == item,
              catalog.contains(where: { $0 == item }) else {
            launcherNoticeMessage = noticeKey("The desktop workspace is unavailable or changed. Reopen it before applying."); settingsNoticeMessage = launcherNoticeMessage; return nil
        }
        let id = UUID(), authorization: ExecutionRequest
        let applications = configurableApplications
        let resource = (item.objectRevision ?? "") + "|" + applications.filter { app in definition.entries.contains(where: { $0.applicationID == app.id }) }.map { $0.id + "|" + ($0.objectRevision ?? "") }.joined(separator: "|")
        do {
            guard let desktopWorkspaceStore else { throw WindowLayoutError.unavailable }
            try desktopWorkspaceStore.validateCurrent()
            authorization = try authorizeHostAction(id: item.id, operation: .applyDesktopWorkspace, resource: resource, caller: caller, invocation: id)
        } catch { showError(error); settingsNoticeMessage = launcherNoticeMessage; return nil }
        guard reserveExecution(id) else { settingsNoticeMessage = launcherNoticeMessage; return nil }
        let group = DesktopOperationGroup(), focusSession: DesktopWorkspaceFocusSession, displays: WindowDisplaySnapshot
        do { displays = try windowLayouts.captureDisplaySnapshot(); focusSession = try DesktopWorkspaceFocusSession(source: source, operations: group) }
        catch { group.revoke(); finishExecutionReservation(id); showError(error); settingsNoticeMessage = launcherNoticeMessage; return nil }
        let previous = desktopLeases.keys.compactMap { taskHandles[$0] } + desktopWorkspaceGroups.keys.compactMap { taskHandles[$0] }
        for (oldID, lease) in desktopLeases { lease.revoke(); taskHandles[oldID]?.cancel() }
        cancelDesktopWorkspaceRuns()
        desktopWorkspaceGroups[id] = (definition.id, group)
        tasks.insert(RunningTaskItem(id: id, title: definition.name, state: .queued), at: 0)
        tasks[0].noticeMessage = noticeKey("Applying desktop workspace…")
        launcherNoticeMessage = tasks[0].noticeMessage; settingsNoticeMessage = .none
        tasks[0].desktopWorkspaceID = definition.id
        tasks[0].desktopWorkspaceResult = .init(entryIDs: definition.entries.map(\.id))
        tasks[0].desktopWorkspaceLabels = Dictionary(uniqueKeysWithValues: definition.entries.compactMap { entry in
            applications.first(where: { $0.id == entry.applicationID }).map { (entry.id, TaskTextLimits.prefix($0.title, maximumBytes: 256)) }
        })
        registerActivity(id, commandID: item.id, category: .window)
        taskHandles[id] = Task { [weak self] in
            guard let self else { return }
            defer { focusSession.close(); desktopWorkspaceGroups[id] = nil; onDesktopActionFinished?(id); finishExecutionReservation(id) }
            var frozenInvocationDisplay = invocationDisplayID
            var preparationError: (any Error)?
            do {
                try focusSession.fence.check()
                if frozenInvocationDisplay == nil && definition.entries.contains(where: { $0.display == .invocationDisplay }) {
                    let target = try await desktop.captureWindowTarget(source)
                    frozenInvocationDisplay = try await windowLayouts.displayID(containing: target, displays: displays)
                    try focusSession.fence.check()
                }
            } catch { preparationError = error; group.revoke() }
            // 原调用仍真实排水；捕获后的源屏幕和拓扑在等待期间不重新选择。
            for worker in previous { await worker.value }
            let report: DesktopWorkspaceRunResult
            if let preparationError {
                report = .init(entryIDs: definition.entries.map(\.id), stop: preparationError is CancellationError ? .cancelled : .failed)
            } else if Task.isCancelled || isShuttingDown || !group.isCurrent {
                report = .init(entryIDs: definition.entries.map(\.id), stop: .cancelled)
            } else {
                updateTask(id, state: .running)
                report = await desktopWorkspaceRunner.run(id: id, definition: definition, catalog: applications, source: source,
                    invocationDisplayID: frozenInvocationDisplay, group: group, focusSession: focusSession, displays: displays, store: invocationStore,
                    commandID: authorization.commandID, commandVersion: authorization.commandVersion, fingerprint: fingerprint(resource), caller: caller.rawValue,
                    didFocus: didFocus, progress: { [weak self] value in self?.setDesktopWorkspaceResult(value, id: id) })
            }
            group.revoke(); setDesktopWorkspaceResult(report, id: id, finished: true)
            updateTask(id, state: stateLabel(report.state), finished: true)
            if report.state != .succeeded { launcherNoticeMessage = desktopWorkspaceNotice(report) }
        }
        return id
    }
    func setDesktopWorkspaceResult(_ value: DesktopWorkspaceRunResult, id: UUID, finished: Bool = false) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].desktopWorkspaceResult = value
        tasks[index].noticeMessage = finished ? desktopWorkspaceNotice(value) : noticeKey("Applying desktop workspace…")
    }
    func desktopWorkspaceNotice(_ value: DesktopWorkspaceRunResult) -> LocalizedNotice {
        if value.receiptUncertain { return noticeKey("Workspace receipt could not be confirmed. Known steps are retained; check applications before starting a new run.") }
        if value.state == .succeeded { return noticeKey("All workspace layouts were confirmed.") }
        if value.state == .cancelled { return noticeKey("Workspace cancelled before any confirmed change. Check any unknown steps before retrying.") }
        return noticeKey("Workspace stopped. Confirmed steps remain; remaining steps were not dispatched. Check unknown results before a new run.")
    }
}
