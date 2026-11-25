import SwiftUI
import AutomationCore
import KeyDockUI

struct WorkflowLaunchView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var launch: WorkflowLaunchDraft
    @FocusState private var inputFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(launch.definition.name).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(L("Enter input for this workflow. Nothing runs until you choose Run workflow.")).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(launch.definition.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text((index + 1).formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title(step)).font(.callout)
                                Text(source(step.input)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 140)
            TextEditor(text: Binding(get: { launch.input }, set: { launch.editInput($0) })).focused($inputFocused).font(.body).frame(minHeight: 120, maxHeight: 180)
                .scrollContentBackground(.hidden).padding(10).modifier(KDReadingSurface()).accessibilityLabel(L("Workflow input"))
            if !launch.notice.isEmpty { KDInlineNotice(launch.notice) }
            HStack {
                Button(L("Cancel")) { session.cancelWorkflowLaunch(launch.id) }.keyboardShortcut(.cancelAction)
                if launch.needsReview { Button(L("Reload saved workflow")) { session.reloadWorkflowLaunch(launch.id, in: store) } }
                Spacer()
                Button(L("Run workflow")) { store.performUserInputAction { session.runWorkflowLaunch(launch.id, in: store) } }.buttonStyle(.borderedProminent)
                    .disabled(!session.canRunWorkflowLaunch(launch.id, in: store))
            }
        }.padding(24).frame(minWidth: 560, idealWidth: 640, maxWidth: 720, minHeight: 440)
            .environment(\.locale, KDLocalizer.locale)
            .task(id: launch.id) { await Task.yield(); inputFocused = true }
    }
    private func title(_ step: WorkflowStep) -> String {
        switch step.operation {
        case .savedCommand(let id): store.configuration.savedCommands.first(where: { $0.id == id })?.name ?? L("Saved command")
        case .aiAction(let id): store.configuration.aiActions.first(where: { $0.id == id })?.displayName ?? L("AI action")
        case .manualInput: L("Ask for input")
        case .transform(let transform): switch transform { case .trim: L("Trim text"); case .uppercase: L("Uppercase"); case .lowercase: L("Lowercase") }
        }
    }
    private func source(_ input: WorkflowInputBinding) -> String {
        switch input { case .workflowInput: L("Workflow input"); case .previousOutput: L("Previous output"); case .literal: L("Fixed text") }
    }
}
