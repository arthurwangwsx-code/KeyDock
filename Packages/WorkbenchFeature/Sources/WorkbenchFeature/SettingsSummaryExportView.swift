import SwiftUI
import UniformTypeIdentifiers
import KeyDockUI

struct SettingsSummaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// 宿主直到实际dismiss才释放；闭包固定该呈现ID，不读取后来创建的另一份审阅身份。
struct SettingsSummarySheetHost: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var presentation: SettingsSummaryPresentation
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { isPresented && !presentation.invalidated }, set: { value in
                if !value { session.closeSettingsSummary(presentation.id) }; isPresented = value
            }), onDismiss: { session.settingsSummaryDidDismiss(presentation.id) }) {
                SettingsSummaryExportView(store: store, session: session, presentation: presentation)
                    .onAppear { session.settingsSummaryDidAppear(presentation.id) }
            }
            .onAppear {
                if !presentation.invalidated { isPresented = true }
                else { session.settingsSummaryDidDismiss(presentation.id) }
            }
            .onChange(of: presentation.invalidated) { _, invalidated in if invalidated { isPresented = false } }
    }
}

struct SettingsSummaryExportView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var presentation: SettingsSummaryPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Export redacted settings summary")).font(.title2.bold())
            Text(L("Save selected preferences, the launcher shortcut and configuration counts as JSON for viewing or sharing. This file cannot restore the app.")).font(.callout).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            Text(L("Custom names, alias contents, prompts, snippets, command arguments, paths, service connections, credentials and history are excluded.")).font(.caption).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            ForEach(SettingsSummarySection.allCases, id: \.self) { section in
                Toggle(section.title, isOn: Binding(get: { presentation.sections.contains(section) }, set: { presentation.setSection(section, selected: $0) }))
                    .toggleStyle(.checkbox).disabled(presentation.isSaving)
            }
            HStack {
                Text(L("JSON preview")).font(.headline)
                Spacer()
                Button(L("Update preview")) { session.refreshSettingsSummary(presentation.id, in: store) }.disabled(presentation.isSaving || presentation.sections.isEmpty)
            }
            if let snapshot = presentation.snapshot {
                ScrollView([.vertical, .horizontal]) {
                    Text(snapshot.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .accessibilityLabel(L("Settings summary JSON preview") + ": " + snapshot.preview)
                }.frame(height: 210).modifier(KDReadingSurface())
            }
            if presentation.needsPreview { Text(L("Your choices changed. Update the preview before saving.")).font(.caption).foregroundStyle(.secondary) }
            if !presentation.notice.rendered().isEmpty { KDInlineNotice(presentation.notice.rendered()) }
            HStack {
                Button(L("Close")) { session.closeSettingsSummary(presentation.id) }.keyboardShortcut(.cancelAction).disabled(presentation.isSaving)
                Spacer()
                if presentation.isSaving { ProgressView().controlSize(.small) }
                Button(L("Save JSON…")) { presentation.beginSave() }.disabled(!presentation.canSave)
            }
            if let attempt = presentation.saveAttempt {
                SettingsSummarySavePanel(attempt: attempt) { outcome in
                    session.finishSettingsSummarySave(presentation.id, attemptID: attempt.id, outcome: outcome)
                }.id(attempt.id)
            }
        }.padding(24).frame(width: 640).interactiveDismissDisabled(presentation.isSaving)
    }
}

/// 子视图固定attempt与Data；系统先收起面板再回调时也不从当前Store重新取值。
private struct SettingsSummarySavePanel: View {
    let attempt: SettingsSummarySaveAttempt
    let finish: (SettingsSummarySaveOutcome) -> Void
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .fileExporter(isPresented: $isPresented, document: SettingsSummaryDocument(data: attempt.snapshot.data), contentTypes: [.json],
                defaultFilename: "KeyDock-settings-summary", onCompletion: { result in
                    switch result { case .success: finish(.saved); case .failure: finish(.failed) }
                }, onCancellation: { finish(.cancelled) })
            .onAppear { isPresented = true }
    }
}
