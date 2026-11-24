import SwiftUI
import UniformTypeIdentifiers
import AutomationCore
import KeyDockUI

struct AggregateDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct ActivityView: View {
    @ObservedObject var store: WorkbenchModel
    @State private var days = 7
    @State private var confirmClear = false
    @State private var export = false
    @State private var document = AggregateDocument(data:Data())
    var body: some View {
        Form {
            Section(L("Usage insights")) {
                Toggle(L("Record KeyDock usage"),isOn:Binding(get:{store.configuration.activityEnabled},set:{ value in Task { await store.setActivityTracking(value) } })).disabled(store.activityChanging)
                Text(L("Optional, local statistics for KeyDock actions only. Stores command IDs, outcomes, durations and dates for 30 days. No window titles, arguments, clipboard text or model input is recorded. This is partial coverage, not whole-computer tracking.")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Time range"),selection:$days) { Text(L("Last 7 days")).tag(7); Text(L("Last 30 days")).tag(30) }.pickerStyle(.segmented)
                HStack {
                    Button(L("Refresh")) { Task { await store.refreshActivity(days:days) } }
                    Button(L("Summarize with AI")) { store.summarizeActivity() }.disabled(store.activityReport?.totalCount ?? 0 == 0)
                    Button(L("Export aggregates")) { prepareExport() }.disabled(store.activityReport == nil)
                    Spacer()
                    Button(L("Clear statistics"),role:.destructive) { confirmClear = true }
                }
            }
            if let report = store.activityReport {
                Section(L("Recorded activity")) {
                    LabeledContent(L("Actions"),value:String(report.totalCount))
                    LabeledContent(L("Average duration"),value:report.averageDuration.map{String(format:"%.2f s",$0)} ?? L("Unknown"))
                    LabeledContent(L("Success rate (known outcomes)"),value:report.successRateAmongKnownCompletions.map{String(format:"%.0f%%",$0*100)} ?? L("Unknown"))
                    Text(L("Daily counts use UTC. Paused and unrecorded actions are outside this report.")).font(.caption).foregroundStyle(.secondary)
                    ForEach(report.days,id:\.utcDate) { day in
                        HStack { Text(day.utcDate).font(.caption.monospaced()); ProgressView(value:Double(day.count),total:Double(max(1,report.days.map(\.count).max() ?? 1))); Text(String(day.count)).monospacedDigit() }
                    }
                }
                Section(L("Most used actions")) {
                    ForEach(report.topCommands,id:\.commandID) { item in HStack { Text(store.activityLabel(item.commandID)).lineLimit(1); Spacer(); Text(String(item.count)).monospacedDigit() } }
                }
            }
        }.formStyle(.grouped).task { await store.refreshActivity(days:days) }
            .onChange(of:days) { _,_ in Task { await store.refreshActivity(days:days) } }
            .confirmationDialog(L("Clear all recorded statistics?"),isPresented:$confirmClear) { Button(L("Clear statistics"),role:.destructive) { Task { await store.clearActivity(); await store.refreshActivity(days:days) } } }
            .fileExporter(isPresented:$export,document:document,contentType:.json,defaultFilename:"KeyDock-aggregates") { result in
                if case .failure = result { store.workspaceNoticeMessage = noticeKey("Export was cancelled or could not be saved") }
            }
    }
    private func prepareExport() {
        guard let report = store.activityReport else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601; document = AggregateDocument(data:try encoder.encode(report)); export = true }
        catch { store.workspaceNoticeMessage = noticeKey("Export was cancelled or could not be saved") }
    }
}
