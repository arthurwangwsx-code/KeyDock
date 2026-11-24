import SwiftUI
import AutomationCore

private struct ScheduleApproval: Identifiable {
    let id = UUID()
    let snapshot: ScheduleSnapshot
    let fingerprint: String
    let review: String
}
struct SchedulePanel: View {
    @ObservedObject var store: WorkbenchModel
    @State private var name = ""
    @State private var workflowID: UUID?
    @State private var daily = false
    @State private var minutes = 60
    @State private var hour = 9
    @State private var minute = 0
    @State private var timeZone = TimeZone.current.identifier
    @State private var approval: ScheduleApproval?
    @State private var removal: ScheduleSnapshot?
    @State private var acknowledge: ScheduleSnapshot?
    @State private var editing: ScheduleSnapshot?
    var body: some View {
        Section(L("Schedules")) {
            Text(L("Runs only while KeyDock is open. Missed times after sleep merge into one run. Interactive steps and dynamic command arguments cannot run unattended. Changed commands or AI targets require a new approval.")).font(.caption).foregroundStyle(.secondary)
            ForEach(store.schedules) { value in
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text(value.definition.name).font(.headline); Spacer()
                        if value.definition.enabled && !store.scheduleSuspended.contains(value.id) {
                            Button(L("Disable")) { Task { await store.setSchedule(value,enabled:false) } }
                        } else {
                            Button(L("Review and enable")) {
                                if let hash = try? store.scheduleFingerprint(value.definition.workflowID) { approval = .init(snapshot:value,fingerprint:hash,review:store.scheduleReview(value.definition.workflowID)) }
                                else { store.workspaceNoticeMessage = noticeKey("This workflow is unavailable for unattended execution. Check its steps and AI configuration.") }
                            }.disabled(value.reviewRequired)
                        }
                        Button(L("Edit")) {
                            editing = value; name = value.definition.name; workflowID = value.definition.workflowID
                            switch value.definition.trigger {
                            case .interval(let seconds): daily = false; minutes = min(10_080,max(1,Int(seconds/60)))
                            case .daily(let h,let m,let zone): daily = true; hour = h; minute = m; timeZone = zone
                            }
                        }
                        Button(L("Remove"),role:.destructive) { removal = value }
                    }
                    Text(value.nextFireAt,style:.date).font(.caption) + Text(" ") + Text(value.nextFireAt,style:.time).font(.caption)
                    if value.activeAttempt != nil { Text(L("Running")).foregroundStyle(.secondary) }
                    if let last = value.lastAttempt { Text(outcome(last.outcome)).font(.caption).foregroundStyle(.secondary) }
                    if value.reviewRequired { Button(L("I checked the unknown result")) { acknowledge = value } }
                }
            }
            TextField(L("Schedule name"),text:$name)
            Picker(L("Workflow"),selection:$workflowID) {
                Text(L("Choose a workflow")).tag(Optional<UUID>.none)
                ForEach(store.configuration.workflows) { Text($0.name).tag(Optional($0.id)) }
            }
            Toggle(L("Daily at a local time"),isOn:$daily)
            if daily {
                Stepper(String(format:L("Hour: %d"),hour),value:$hour,in:0...23)
                Stepper(String(format:L("Minute: %d"),minute),value:$minute,in:0...59)
                TextField(L("Time zone identifier"),text:$timeZone)
            } else { Stepper(String(format:L("Every %d minutes"),minutes),value:$minutes,in:1...10_080) }
            Button(L("Save disabled schedule")) {
                guard let workflowID else { return }
                let trigger: ScheduleTrigger = daily ? .daily(hour:hour,minute:minute,timeZoneID:timeZone):.interval(seconds:Double(minutes)*60)
                Task { if let editing { await store.editSchedule(editing,name:name,workflowID:workflowID,trigger:trigger) } else { await store.addSchedule(name:name,workflowID:workflowID,trigger:trigger) }; editing = nil }
            }.disabled(workflowID == nil || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            if editing != nil { Button(L("Cancel editing")) { editing = nil; name = ""; workflowID = nil } }
        }.disabled(store.scheduleBusy)
            .sheet(item:$approval) { value in
                VStack(alignment:.leading,spacing:16) {
                    Text(L("Approve unattended workflow")).font(.title2)
                    Text(L("This saved workflow may launch commands and send its input or output to the displayed AI service without another prompt at each scheduled time. Review every command and destination."))
                    ScrollView { Text(value.review).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(height:220)
                    HStack { Button(L("Cancel")) { approval = nil }; Spacer(); Button(L("Enable schedule")) { approval = nil; Task { await store.setSchedule(value.snapshot,enabled:true,approvedFingerprint:value.fingerprint) } }.buttonStyle(.borderedProminent) }
                }.padding(24).frame(width:580)
            }
            .confirmationDialog(L("Remove this schedule?"),isPresented:Binding(get:{removal != nil},set:{if !$0 { removal = nil }})) {
                Button(L("Remove"),role:.destructive) { if let value = removal { Task { await store.removeSchedule(value) } }; removal = nil }
            }
            .confirmationDialog(L("Confirm that you checked any effects. This does not retry the unknown run."),isPresented:Binding(get:{acknowledge != nil},set:{if !$0 { acknowledge = nil }})) {
                Button(L("Confirm review")) { if let value = acknowledge { Task { await store.acknowledgeSchedule(value) } }; acknowledge = nil }
            }
    }
    private func outcome(_ value:ScheduleAttemptOutcome?) -> String { switch value { case .succeeded: L("Completed"); case .failed:L("Failed"); case .cancelled:L("Cancelled"); default:L("Interrupted / unknown outcome") } }
}
