import AppKit
import CommandCore

/// 每次调用独占一个session和冻结计划，关闭后不能重试或重绑窗口。
@MainActor final class NativeDesktopWorkspaceRun {
    let definition: SavedDesktopWorkspace
    let catalog: [CommandItem]
    let source: TargetIdentity
    var invocationDisplay: String?
    let group: DesktopOperationGroup
    let session: DesktopWorkspaceFocusSession
    let desktop: DesktopService
    let applications: DesktopApplicationPreparationService
    let layouts: WindowLayoutController
    let focus = WorkspaceWindowFocusController()
    var displays: WindowDisplaySnapshot?
    var prepared: [PreparedWorkspaceApplication] = []
    var ready: [Int: ReadyDesktopApplication] = [:]
    var plans: [Int: PreparedWindowLayout] = [:]
    init(definition: SavedDesktopWorkspace, catalog: [CommandItem], source: TargetIdentity, invocationDisplay: String?,
         group: DesktopOperationGroup, desktop: DesktopService, applications: DesktopApplicationPreparationService, layouts: WindowLayoutController, focusSession: DesktopWorkspaceFocusSession? = nil, displaySnapshot: WindowDisplaySnapshot? = nil) throws {
        self.definition = definition; self.catalog = catalog; self.source = source; self.invocationDisplay = invocationDisplay
        displays = displaySnapshot
        self.group = group; self.desktop = desktop; self.applications = applications; self.layouts = layouts
        if let focusSession {
            guard focusSession.fence.operations === group else { throw WindowCommandError.changed }
            session = focusSession; try session.fence.check()
        } else { session = try DesktopWorkspaceFocusSession(source: source, operations: group) }
    }
    var operations: DesktopWorkspaceRunOperations {
        .init(preflight: { try await self.preflight() }, launch: { index, lease in
            self.ready[index] = try await self.applications.ensureRunning(self.prepared[index].plan, lease: lease)
        }, prepareLaunchedWindow: { try await self.prepareWindow($0, waitForNewWindow: true) },
        revalidateAll: { try await self.revalidateAll() }, focus: { index, lease in
            guard let plan = self.plans[index], let ready = self.ready[index] else { throw WindowLayoutError.unavailable }
            try await self.applications.revalidate(ready); try await self.layouts.revalidate(plan); try self.check()
            try await self.focus.focus(plan.target, fence: self.session.fence, lease: lease)
        }, layout: { index, lease in
            guard let plan = self.plans[index], let ready = self.ready[index] else { throw WindowLayoutError.unavailable }
            try await self.applications.revalidate(ready); try self.check()
            try await self.layouts.applyPrepared(plan, lease: lease, requiresFocusedWindow: true)
        }, check: { try self.check() }, close: { self.session.close() })
    }
    func check() throws {
        session.fence.observe(WorkspaceWindowFocusController.foregroundIdentity()); try session.fence.check(); try group.check()
    }
    func preflight() async throws -> [Bool] {
        try check()
        guard desktop.accessibilityGranted else { throw DesktopError.accessibilityRequired }
        let current = try layouts.captureDisplaySnapshot(), snapshot = displays ?? current
        guard snapshot.matches(current) else { throw WindowLayoutError.changed }; displays = snapshot
        if definition.entries.contains(where: { $0.display == .invocationDisplay }) {
            if invocationDisplay == nil {
                // 直接热键按真实调用应用的原窗口定位，不要求该源窗口支持缩放。
                let target = try await desktop.captureWindowTarget(source)
                invocationDisplay = try await layouts.displayID(containing: target, displays: snapshot)
            }
            guard snapshot.displays.contains(where: { $0.id == invocationDisplay }) else { throw WindowLayoutError.unavailable }
        }
        try check()
        prepared = try await applications.inspectWorkspace(definition, applications: catalog, fence: session.fence)
        for index in prepared.indices where prepared[index].plan.initialIdentity != nil {
            let lease = try group.makeChild()
            do { ready[index] = try await applications.ensureRunning(prepared[index].plan, lease: lease); group.release(lease) }
            catch { group.release(lease); throw error }
            try await prepareWindow(index, waitForNewWindow: false)
        }
        // 已运行窗口全部准备好以后才允许提交任何后台启动。
        try await revalidateAll(requireComplete: false); try check()
        return prepared.map { $0.plan.initialIdentity == nil }
    }
    func prepareWindow(_ index: Int, waitForNewWindow: Bool) async throws {
        guard let ready = ready[index], let displays else { throw WindowLayoutError.unavailable }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let target: DesktopWindowTarget
        while true {
            try check(); try await applications.revalidate(ready)
            do { target = try await desktop.captureWindowTarget(ready.identity); break }
            catch {
                try check()
                guard waitForNewWindow, ContinuousClock.now < deadline, !(error is CancellationError) else { throw error }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try check()
        guard !plans.values.contains(where: { $0.target.identity.pid == target.identity.pid || CFEqual($0.target.reference.element, target.reference.element) }) else { throw WindowLayoutError.changed }
        let entry = definition.entries[index]
        let prepared = try await layouts.prepareWorkspaceWindows([.init(entryID: entry.id, target: target, layout: entry.layout, display: entry.display)], displays: displays, invocationDisplayID: invocationDisplay)
        try check(); plans[index] = prepared[0].plan
    }
    func revalidateAll(requireComplete: Bool = true) async throws {
        try check()
        if requireComplete { guard plans.count == definition.entries.count, ready.count == definition.entries.count else { throw WindowLayoutError.changed } }
        if let displays { guard displays.matches(try layouts.captureDisplaySnapshot()) else { throw WindowLayoutError.changed } }
        for index in definition.entries.indices {
            try check()
            if let ready = ready[index] { try await applications.revalidate(ready) }
            else if prepared.indices.contains(index) { try await applications.revalidate(prepared[index].plan) }
            if let plan = plans[index] { try await layouts.revalidate(plan) }
        }
        try check()
    }
}
