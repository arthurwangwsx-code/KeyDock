import SwiftUI
import AutomationCore
import KeyDockUI

struct WorkflowWorkspaceView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @State private var confirmRemoval = false
    var body: some View {
        Form {
            Section(L("Workflows")) {
                Picker(L("Workflow"),selection:Binding(get:{session.workflowDraft.id},set:{ id in if let value = store.configuration.workflows.first(where:{$0.id == id}) { session.workflowDraft = value } })) {
                    if !store.configuration.workflows.contains(where:{$0.id == session.workflowDraft.id}) { Text(L("Unsaved workflow")).tag(session.workflowDraft.id) }
                    ForEach(store.configuration.workflows) { item in Text(item.name).tag(item.id) }
                }
                HStack {
                    TextField(L("Name"),text:$session.workflowDraft.name)
                    Button(L("New workflow")) { session.workflowDraft = WorkflowDefinition(name:"",steps:[.init(operation:.transform(.trim))]) }
                    Button(L("Save workflow")) { session.saveWorkflow(in: store) }
                    if store.configuration.workflows.contains(where:{$0.id == session.workflowDraft.id}) { Button(L("Remove"),role:.destructive) { confirmRemoval = true } }
                }
                let saveState = session.workflowSaveState(in: store)
                Label(saveState.title, systemImage: saveState.symbol).font(.caption).foregroundStyle(.secondary)
                Text(L("Steps use a frozen snapshot of saved commands and AI actions. Review commands before starting. Only a whole {{input}} argument passes this step's input; shell-mode commands cannot use that placeholder.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach($session.workflowDraft.steps) { $step in
                Section {
                    HStack {
                        Text(L("Step")+" \((session.workflowDraft.steps.firstIndex(where:{$0.id == step.id}) ?? 0)+1)").font(.headline)
                        Spacer()
                        Button { move(step.id,by:-1) } label: { Image(systemName:"arrow.up") }.accessibilityLabel(L("Move step up"))
                        Button { move(step.id,by:1) } label: { Image(systemName:"arrow.down") }.accessibilityLabel(L("Move step down"))
                        Button(L("Remove"),role:.destructive) { session.workflowDraft.steps.removeAll{$0.id == step.id} }
                    }
                    WorkflowStepEditor(step:$step,store:store)
                }
            }
            Section {
                Button(L("Add step")) { if session.workflowDraft.steps.count < 20 { session.workflowDraft.steps.append(.init(operation:.transform(.trim),input:.previousOutput)) } }.disabled(session.workflowDraft.steps.count >= 20)
                TextEditor(text:$session.workflowInput).font(.body).frame(minHeight:100).modifier(KDReadingSurface()).accessibilityLabel(L("Workflow input"))
                Button(L("Run workflow")) { store.performUserInputAction { store.runWorkflow(session.workflowDraft,input:session.workflowInput) } }.buttonStyle(.borderedProminent)
            }
            SchedulePanel(store:store)
        }.formStyle(.grouped).confirmationDialog(L("Remove this workflow? Its schedules will pause and running tasks keep their snapshot."),isPresented:$confirmRemoval) { Button(L("Remove"),role:.destructive) { if store.removeWorkflow(session.workflowDraft.id) { session.workflowDraft = WorkflowDefinition(name:"",steps:[.init(operation:.transform(.trim))]) } } }.onAppear {
            if !session.workflowLoaded { if let value = store.configuration.workflows.first { session.workflowDraft = value }; session.workflowLoaded = true }
        }
    }
    private func move(_ id: UUID,by offset:Int) {
        guard let index = session.workflowDraft.steps.firstIndex(where:{$0.id == id}), session.workflowDraft.steps.indices.contains(index+offset) else { return }
        session.workflowDraft.steps.swapAt(index,index+offset)
    }
}

private struct WorkflowStepEditor: View {
    @Binding var step: WorkflowStep
    @ObservedObject var store: WorkbenchModel
    var body: some View {
        Picker(L("Action"),selection:Binding(get:{operationKey},set:{setOperation($0)})) {
            Text(L("Trim text")).tag("transform:trim")
            Text(L("Uppercase")).tag("transform:uppercase")
            Text(L("Lowercase")).tag("transform:lowercase")
            Text(L("Ask for input")).tag("manual")
            ForEach(store.configuration.savedCommands.filter{!$0.interactive}) { item in Text(item.name).tag("command:"+item.id.uuidString) }
            ForEach(store.configuration.aiActions) { item in Text(item.displayName).tag("ai:"+item.id.uuidString) }
        }
        Picker(L("Input source"),selection:Binding(get:{inputKey},set:{setInput($0)})) {
            Text(L("Workflow input")).tag("input"); Text(L("Previous output")).tag("previous"); Text(L("Fixed text")).tag("literal")
        }
        if case .literal(let text) = step.input { TextField(L("Fixed text"),text:Binding(get:{ if case .literal(let current) = step.input { current } else { text } },set:{step.input = .literal($0)})) }
    }
    private var operationKey: String {
        switch step.operation { case .savedCommand(let id): "command:"+id.uuidString; case .aiAction(let id): "ai:"+id.uuidString; case .manualInput: "manual"; case .transform(let value): "transform:"+value.rawValue }
    }
    private var inputKey: String { switch step.input { case .workflowInput: "input"; case .previousOutput:"previous"; case .literal:"literal" } }
    private func setInput(_ key: String) { switch key { case "previous": step.input = .previousOutput; case "literal": step.input = .literal(""); default: step.input = .workflowInput } }
    private func setOperation(_ key: String) {
        if key == "manual" { step.operation = .manualInput }
        else if key.hasPrefix("command:"),let id = UUID(uuidString:String(key.dropFirst(8))) { step.operation = .savedCommand(id) }
        else if key.hasPrefix("ai:"),let id = UUID(uuidString:String(key.dropFirst(3))) { step.operation = .aiAction(id) }
        else if key.hasPrefix("transform:"),let value = WorkflowTextTransform(rawValue:String(key.dropFirst(10))) { step.operation = .transform(value) }
    }
}

struct WorkflowInputView: View {
    @ObservedObject var store: WorkbenchModel
    let request: PendingWorkflowInput
    @State private var text = ""
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("Workflow needs input")).font(.headline)
            TextEditor(text:$text).frame(minHeight:80,maxHeight:160).modifier(KDReadingSurface()).accessibilityLabel(L("Workflow input"))
            HStack {
                Button(L("Cancel")) { store.cancelTask(request.runID) }
                Button(L("Continue")) { store.resolveWorkflowInput(request.id,value:text) }.buttonStyle(.borderedProminent)
            }
        }.onAppear { text = request.initialValue }
    }
}
