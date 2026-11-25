import Foundation
import Combine
import AutomationCore

/// 运行输入与工作流编辑稿分离；每次呈现都有独立身份，迟到按钮不能启动另一份请求。
@MainActor final class WorkflowLaunchDraft: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var definition: WorkflowDefinition
    @Published private(set) var input = ""
    @Published private(set) var inputRejected = false
    @Published var needsReview = false
    @Published var noticeMessage: LocalizedNotice = .none
    var notice: String { noticeMessage.rendered(maximumBytes: 8_192) }
    init(_ definition: WorkflowDefinition) { self.definition = definition }
    func reload(_ definition: WorkflowDefinition) {
        self.definition = definition; needsReview = false
        noticeMessage = inputRejected ? noticeKey("Input is too long. Split it into smaller parts; nothing was sent.") : .none
    }
    func editInput(_ value: String) {
        guard value.utf8.count <= TaskTextLimits.inputBytes else {
            inputRejected = true; noticeMessage = noticeKey("Input is too long. Split it into smaller parts; nothing was sent."); return
        }
        input = value; inputRejected = false
        if !needsReview { noticeMessage = .none }
    }
}

extension WorkspaceSession {
    @discardableResult func prepareWorkflowLaunch(_ id: UUID, in store: WorkbenchModel) -> Bool {
        guard !store.isShuttingDown else { return false }
        guard savedToolRemoval == nil else {
            store.workspaceNoticeMessage = noticeKey("Finish or cancel the saved item review before opening another action.")
            return false
        }
        if let current = workflowLaunch {
            guard current.definition.id != id else { return true }
            current.noticeMessage = noticeKey("Finish or cancel the current workflow input before opening another.")
            return false
        }
        guard let definition = store.configuration.workflows.first(where: { $0.id == id }) else {
            store.workspaceNoticeMessage = noticeKey("This saved workflow is no longer available."); return false
        }
        do { _ = try store.compileWorkflow(definition) }
        catch { store.workspaceNoticeMessage = noticeKey("Workflow could not start. Check its steps and AI configuration."); return false }
        workflowLaunch = WorkflowLaunchDraft(definition)
        return true
    }
    func cancelWorkflowLaunch(_ id: UUID) { if workflowLaunch?.id == id { workflowLaunch = nil } }
    func canRunWorkflowLaunch(_ id: UUID, in store: WorkbenchModel) -> Bool {
        guard !store.isShuttingDown, let launch = workflowLaunch, launch.id == id else { return false }
        return !launch.needsReview && !launch.inputRejected && !launch.input.isEmpty && launch.input.utf8.count <= TaskTextLimits.inputBytes
    }
    @discardableResult func reloadWorkflowLaunch(_ id: UUID, in store: WorkbenchModel) -> Bool {
        guard !store.isShuttingDown, let launch = workflowLaunch, launch.id == id else { return false }
        guard let current = store.configuration.workflows.first(where: { $0.id == launch.definition.id }) else {
            launch.needsReview = true; launch.noticeMessage = noticeKey("This saved workflow is no longer available."); return false
        }
        do { _ = try store.compileWorkflow(current) }
        catch { launch.needsReview = true; launch.noticeMessage = noticeKey("Workflow could not start. Check its steps and AI configuration."); return false }
        launch.reload(current); return true
    }
    @discardableResult func runWorkflowLaunch(_ id: UUID, in store: WorkbenchModel) -> Bool {
        guard canRunWorkflowLaunch(id, in: store), let launch = workflowLaunch else { return false }
        guard let current = store.configuration.workflows.first(where: { $0.id == launch.definition.id }) else {
            launch.needsReview = true; launch.noticeMessage = noticeKey("This saved workflow is no longer available."); return false
        }
        guard current == launch.definition else {
            launch.needsReview = true; launch.noticeMessage = noticeKey("The saved workflow changed. Reload it and review the steps before running."); return false
        }
        guard store.runWorkflow(launch.definition, input: launch.input) != nil else {
            launch.noticeMessage = noticeKey("Workflow could not start. Check its steps and AI configuration."); return false
        }
        if workflowLaunch?.id == id { workflowLaunch = nil }
        return true
    }
}
