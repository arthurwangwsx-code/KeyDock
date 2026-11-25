import Foundation
import CommandCore
import ExecutionCore

/// 所有异步端口必须等待自己的真实worker；不能以取消continuation冒充收口。
@MainActor struct DesktopWorkspaceRunOperations {
    var preflight: () async throws -> [Bool]
    var launch: (Int, DesktopOperationLease) async throws -> Void
    var prepareLaunchedWindow: (Int) async throws -> Void
    var revalidateAll: () async throws -> Void
    var focus: (Int, DesktopOperationLease) async throws -> Void
    var layout: (Int, DesktopOperationLease) async throws -> Void
    var check: () throws -> Void
    var close: () -> Void
}

@MainActor struct DesktopWorkspaceJournal {
    var begin: (UUID, DesktopWorkspaceReceiptContext?) async throws -> Void
    var finish: (UUID, ProcessResult, DesktopWorkspaceRunResult?) async throws -> Void
    var abandon: (UUID) async -> Void
    var release: (UUID) async -> Void
    var releaseParent: (UUID) async -> Void
}

/// 组合层只串行派发；取消立即关group，但父handle在原生worker及回执收口前保持占位。
@MainActor public final class DesktopWorkspaceRunner {
    typealias Factory = (SavedDesktopWorkspace, [CommandItem], TargetIdentity, String?, DesktopOperationGroup, DesktopWorkspaceFocusSession?, WindowDisplaySnapshot?) throws -> DesktopWorkspaceRunOperations
    private let factory: Factory
    public convenience init(desktop: DesktopService, applications: DesktopApplicationPreparationService, layouts: WindowLayoutController) {
        self.init(factory: { definition, catalog, source, display, group, focusSession, displays in
            let run = try NativeDesktopWorkspaceRun(definition: definition, catalog: catalog, source: source, invocationDisplay: display,
                group: group, desktop: desktop, applications: applications, layouts: layouts, focusSession: focusSession, displaySnapshot: displays)
            return run.operations
        })
    }
    init(factory: @escaping Factory) { self.factory = factory }
    public func run(id: UUID, definition: SavedDesktopWorkspace, catalog: [CommandItem], source: TargetIdentity,
                    invocationDisplayID: String?, group: DesktopOperationGroup, focusSession: DesktopWorkspaceFocusSession? = nil, displays: WindowDisplaySnapshot? = nil, store: InvocationStore,
                    commandID: String, commandVersion: Int, fingerprint: String, caller: String,
                    didFocus: @escaping @MainActor () -> Void = {},
                    progress: @escaping @MainActor (DesktopWorkspaceRunResult) -> Void = { _ in }) async -> DesktopWorkspaceRunResult {
        let manifest: DesktopWorkspaceRunContext
        do { manifest = try .init(workspaceID: definition.id, revision: definition.revision, entryIDs: definition.entries.map(\.id)) }
        catch { return .init(entryIDs: definition.entries.map(\.id), receiptUncertain: true) }
        let journal = DesktopWorkspaceJournal(begin: { child, context in
            try await store.begin(id: child, name: context == nil ? "Desktop workspace" : "Workspace step",
                commandID: context?.commandID ?? commandID, commandVersion: commandVersion, configurationFingerprint: fingerprint,
                caller: caller, initialMessage: "workspace.intent", desktopWorkspace: context, desktopWorkspaceRun: context == nil ? manifest : nil)
        }, finish: { try await store.finish(id: $0, result: $1, desktopWorkspaceResult: $2) },
        abandon: { await store.abandonUndispatched($0) }, release: { await store.releaseProtection(for: $0) },
        releaseParent: { await store.releaseParentProtection(for: $0) })
        return await run(id: id, definition: definition, catalog: catalog, source: source, invocationDisplayID: invocationDisplayID,
            group: group, focusSession: focusSession, displays: displays, journal: journal, didFocus: didFocus, progress: progress)
    }
    func run(id: UUID, definition: SavedDesktopWorkspace, catalog: [CommandItem], source: TargetIdentity,
             invocationDisplayID: String?, group: DesktopOperationGroup, focusSession: DesktopWorkspaceFocusSession? = nil, displays: WindowDisplaySnapshot? = nil, journal: DesktopWorkspaceJournal,
             didFocus: @escaping @MainActor () -> Void = {}, progress: @escaping @MainActor (DesktopWorkspaceRunResult) -> Void = { _ in }) async -> DesktopWorkspaceRunResult {
        await withTaskCancellationHandler {
            var result = DesktopWorkspaceRunResult(entryIDs: definition.entries.map(\.id))
            let operations: DesktopWorkspaceRunOperations
            do { try group.check(); operations = try factory(definition, catalog, source, invocationDisplayID, group, focusSession, displays) }
            catch { result.stop = error is CancellationError ? .cancelled : .failed; group.revoke(); return result }
            defer { operations.close(); group.revoke() }
            do { try await journal.begin(id, nil) }
            catch {
                result.receiptUncertain = true
                await journal.abandon(id); await journal.releaseParent(id); progress(result); return result
            }
            do {
                try operations.check()
                let missing = try await operations.preflight()
                guard missing.count == definition.entries.count else { throw WindowLayoutError.changed }
                try operations.check()
                for index in missing.indices where !missing[index] { result.entries[index].launch = .notRequired }
                progress(result)
                for index in missing.indices where missing[index] {
                    try await step(index, phase: .launch, parent: id, definition: definition, group: group, journal: journal,
                                   operations: operations, result: &result, body: operations.launch)
                    progress(result)
                    try operations.check()
                    try await operations.prepareLaunchedWindow(index)
                }
                try operations.check(); try await operations.revalidateAll(); try operations.check()
                for index in definition.entries.indices {
                    try await step(index, phase: .focus, parent: id, definition: definition, group: group, journal: journal,
                                   operations: operations, result: &result, body: operations.focus)
                    progress(result)
                    // 只隐藏已失焦Launcher；不能激活任务页打断下一次精确交接。
                    didFocus()
                    try operations.check()
                    try await step(index, phase: .layout, parent: id, definition: definition, group: group, journal: journal,
                                   operations: operations, result: &result, body: operations.layout)
                    progress(result)
                }
                result.stop = .completed
            } catch {
                result.stop = error is CancellationError ? .cancelled : .failed
                group.revoke()
            }
            group.revoke()
            // 原生确认与存储确认分开；finish失败不能抹掉任何已确认阶段。
            do { try await journal.finish(id, .init(state: result.state, message: "workspace.result"), result) }
            catch { result.receiptUncertain = true }
            progress(result)
            await journal.release(id); await journal.releaseParent(id)
            return result
        } onCancel: { group.revoke() }
    }
    private func step(_ index: Int, phase: DesktopWorkspaceReceiptPhase, parent: UUID, definition: SavedDesktopWorkspace,
                      group: DesktopOperationGroup, journal: DesktopWorkspaceJournal, operations: DesktopWorkspaceRunOperations,
                      result: inout DesktopWorkspaceRunResult, body: (Int, DesktopOperationLease) async throws -> Void) async throws {
        try operations.check()
        let lease = try group.makeChild(), id = UUID()
        defer { group.release(lease) }
        let context = try DesktopWorkspaceReceiptContext(parentID: parent, entryID: definition.entries[index].id, entryIndex: index, phase: phase)
        do { try await journal.begin(id, context) }
        catch { result.receiptUncertain = true; await journal.abandon(id); throw error }
        var failure: (any Error)?
        do {
            try operations.check(); try lease.check()
            try await body(index, lease)
            result.entries[index][phase] = .confirmed
        } catch {
            failure = error
            result.entries[index][phase] = lease.didSubmit ? .unknown : (error is CancellationError ? .notExecuted : .declined)
        }
        let fact = result.entries[index][phase]
        let state: ExecutionState = fact == .confirmed ? .succeeded : (fact == .unknown ? .interrupted : (fact == .notExecuted ? .cancelled : .failed))
        let message = fact == .confirmed ? "workspace.confirmed" : (fact == .unknown ? "workspace.unknown" : (fact == .notExecuted ? "workspace.notExecuted" : "workspace.declined"))
        do { try await journal.finish(id, .init(state: state, message: message), nil) }
        catch { result.receiptUncertain = true; failure = error }
        await journal.release(id)
        if let failure { throw failure }
        try operations.check()
    }
}
