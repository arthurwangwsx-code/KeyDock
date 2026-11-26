import AppKit
import CommandCore
import ExecutionCore
import MacAdapters

extension WorkbenchModel {
    public func isDesktopCommand(_ id: String) -> Bool { catalog.first(where: { $0.id == id }).map { $0.kind == .application || isDesktopItem($0) } ?? false }
    public func desktopShortcut(_ id: String) { if let item = catalog.first(where: { $0.id == id }), isDesktopCommand(id) { onDesktopAction?(item, .shortcut) } }
    func isDesktopItem(_ item: CommandItem) -> Bool {
        isDesktopWorkspace(item) || item.payload.hasPrefix("window-layout.") || item.payload.hasPrefix("window-command.") || item.payload.hasPrefix("application-action.")
    }
    public var configurableApplications: [CommandItem] { catalog.filter { $0.kind == .application } }
    @discardableResult public func saveApplicationAction(_ action: SavedApplicationAction, expectedRevision: String? = nil, creating: Bool = false) -> Bool {
        guard !isShuttingDown, applicationActionsWritable else { return false }
        if creating, applicationActions.contains(where: { $0.id == action.id }) {
            settingsNoticeMessage = noticeKey("This application action was removed or changed. Keep this draft and edit the current version or create a new action."); return false
        }
        if let expectedRevision {
            guard let current = applicationActions.first(where: { $0.id == action.id }), applicationActionRevision(current) == expectedRevision else {
                settingsNoticeMessage = noticeKey("This application action was removed or changed. Keep this draft and edit the current version or create a new action."); return false
            }
        }
        var values = applicationActions
        if let i = values.firstIndex(where: { $0.id == action.id }) { values[i] = action } else { values.append(action) }
        var next = configuration; next.savedApplicationActions = values
        return commitShortcutConfiguration(next)
    }
    /// 无UI调用者也必须经过同一引用／指纹／候选事务；UI持有最初的审阅身份。
    @discardableResult public func deleteApplicationAction(_ id: UUID) -> Bool {
        guard let reviewed = reviewSavedItemRemoval(.applicationAction(id)) else { return false }
        return removeSavedItem(reviewed)
    }

    /// 不显示Launcher，不读选区正文。进程/窗口上下文由真实UI组合根提供。
    @discardableResult public func runDesktopCommand(_ item: CommandItem, original: TargetIdentity?, window: DesktopWindowTarget?, caller: ExecutionCaller, lease: DesktopOperationLease, captureFrontmostWindow: Bool = true) -> UUID? {
        if item.payload.hasPrefix("application-action."), !validateApplicationActionSource() { return nil }
        guard !isShuttingDown, catalog.contains(where: { $0.id == item.id && $0.objectRevision == item.objectRevision }) else { return nil }
        let operation: HostOperation
        let layout = item.payload.hasPrefix("window-layout.") ? WindowLayout(rawValue: String(item.payload.dropFirst(14))) : nil
        let windowCommand = item.payload.hasPrefix("window-command.") ? WindowCommand(rawValue: String(item.payload.dropFirst(15))) : nil
        let definition = applicationActions.first { "application-action." + $0.id.uuidString == item.id }
        let application = item.kind == .application ? item : definition.flatMap { action in configurableApplications.first { $0.id == action.applicationID } }
        let behavior = definition?.behavior ?? .launchOrActivate
        if layout != nil { operation = .layoutWindow }
        else if let windowCommand { operation = windowCommand == .minimize ? .minimizeWindow : .cycleWindow }
        else if application != nil { operation = Self.operation(for: behavior) }
        else { launcherNoticeMessage = noticeKey("The shortcut target is no longer available"); return nil }
        let needsWindow = layout != nil || windowCommand != nil
        guard !needsWindow || (allowContextCapture && original != nil) else { launcherNoticeMessage = noticeKey("No original window is available"); return nil }
        let id = UUID(), resource = item.id + "|" + (item.objectRevision ?? "") + "|" + (application?.objectRevision ?? "") + "|" + (original.map { "\($0.pid)|\($0.launchDate?.timeIntervalSince1970 ?? 0)" } ?? "")
        let authorization: ExecutionRequest
        do {
            authorization = try authorizeHostAction(id: item.id, operation: operation, resource: resource,
                availableContext: needsWindow ? [.window] : [], caller: caller, invocation: id)
        } catch { showError(error); return nil }
        guard reserveExecution(id) else { return nil }
        // Capture the window at admission. A refused capture still receives its normal intent and outcome.
        let capturedWindow = Result<DesktopWindowTarget?, Error> {
            guard layout != nil || windowCommand == .minimize else { return nil }
            guard let original, let birth = original.launchDate else { throw DesktopError.targetExpired }
            let target: DesktopWindowTarget
            if let window { target = window }
            else if captureFrontmostWindow { target = try desktop.freezeFrontmostWindow(original) }
            else { throw DesktopError.targetExpired }
            guard target.identity.pid == original.pid, target.identity.launchDate == birth else { throw DesktopError.targetExpired }
            return target
        }
        let previousWorkspaceRuns = desktopWorkspaceGroups.keys.compactMap { taskHandles[$0] }
        cancelDesktopWorkspaceRuns()
        desktopLeases[id] = lease
        tasks.insert(RunningTaskItem(id: id, title: item.title, state: .queued), at: 0)
        registerActivity(id, commandID: item.id, category: needsWindow ? .window : .application)
        taskHandles[id] = Task { [weak self] in
            guard let self else { return }
            defer { desktopLeases[id] = nil; onDesktopActionFinished?(id); finishExecutionReservation(id) }
            for handle in previousWorkspaceRuns { await handle.value }
            var result: DesktopControlOutcome
            var failureReason = "unavailable"
            do {
                try await invocationStore.begin(id: id, name: "Desktop action", commandID: authorization.commandID, commandVersion: authorization.commandVersion,
                    configurationFingerprint: fingerprint(resource), caller: caller.rawValue, initialMessage: "desktop.intent")
                try lease.check(); try Task.checkCancellation()
                guard !isShuttingDown else { throw CancellationError() }
                updateTask(id, state: .running)
                let frozenWindow = try capturedWindow.get()
                if let layout, let frozenWindow {
                    try await windowLayouts.apply(layout, target: frozenWindow, lease: lease, restoreFocus: true, requiresFocusedWindow: true)
                    result = .confirmed
                } else if let windowCommand, let original {
                    result = try await windowCommands.perform(windowCommand, identity: original, target: frozenWindow, lease: lease)
                } else if let application {
                    result = try await applicationControl.perform(behavior, item: application, original: original, lease: lease)
                } else { throw ApplicationControlError.unavailable }
                try lease.check()
            } catch {
                failureReason = Self.desktopFailureReason(error)
                result = lease.didSubmit ? .outcomeUnknown : (error is CancellationError ? .cancelledBeforeDispatch : .declined)
            }
            let state: ExecutionState
            let message: String
            let notice: LocalizedNotice
            switch result {
            case .confirmed: state = .succeeded; message = "desktop.confirmed"; notice = noticeKey("Desktop action confirmed")
            case .noOp: state = .succeeded; message = "desktop.noOp"; notice = noticeKey("The application or window is already in the requested state")
            case .requestSubmitted:
                state = .interrupted
                if behavior == .showAllWindows {
                    message = "desktop.windowsRequested"; notice = noticeKey("macOS accepted the request to bring all application windows forward. Check their arrangement; minimized windows and Spaces were not individually verified.")
                } else {
                    message = "desktop.quitRequested"; notice = noticeKey("Quit was requested once. The application may be waiting for you to save; check it before retrying.")
                }
            case .declined:
                state = .failed
                message = "desktop.declined." + (lease.didSubmit ? "systemRequest" + (lease.lastNativeOperation.map { "." + $0.rawValue } ?? "") : failureReason)
                notice = lease.didSubmit ? noticeKey("macOS declined the application request. Check the target application before trying again.") : noticeKey("The desktop target is unavailable or changed. Refresh it and try again.")
            case .cancelledBeforeDispatch: state = .cancelled; message = "desktop.cancelled"; notice = noticeKey("Cancelled before execution")
            case .outcomeUnknown: state = .interrupted; message = "desktop.unknown"; notice = noticeKey("A desktop request may already have taken effect. Check the target application before retrying.")
            }
            do { try await invocationStore.finish(id: id, result: ProcessResult(state: state, message: message)) }
            catch { workspaceNoticeMessage = noticeKey("Execution finished, but its receipt could not be saved. Do not rerun automatically.") }
            updateTask(id, state: stateLabel(state), finished: true)
            if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].noticeMessage = notice }
        }
        return id
    }
    static func operation(for behavior: ApplicationBehavior) -> HostOperation {
        switch behavior {
        case .hide: .hideApplication
        case .show: .showApplication
        case .showAllWindows: .showAllApplicationWindows
        case .requestQuit: .quitApplication
        case .launchOrActivate, .toggleVisibility: .openApplication
        }
    }
    /// 回执只记录固定分类，不序列化跨进程错误、路径、标题或正文。
    private static func desktopFailureReason(_ error: any Error) -> String {
        if let error = error as? ApplicationControlError {
            switch error {
            case .unavailable: return "applicationUnavailable"
            case .changed: return "applicationChanged"
            case .ambiguous: return "ambiguousInstances"
            case .launchUnknown: return "launchUnconfirmed"
            }
        }
        if error is ApplicationCatalogError { return "applicationCatalog" }
        if error is InvocationStoreError { return "receiptUnavailable" }
        if error is DesktopError { return "windowContext" }
        if error is WindowCommandError || error is WindowLayoutError { return "windowUnavailable" }
        return error is CancellationError ? "cancelled" : "unavailable"
    }
}
