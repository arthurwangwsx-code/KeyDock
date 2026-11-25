import SwiftUI
import KeyDockUI

struct ConfigurationExportSheetHost: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var presentation: ConfigurationExportPresentation
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { isPresented && !presentation.invalidated }, set: { value in
                if !value { session.closeConfigurationExport(presentation.id) }; isPresented = value
            }), onDismiss: { session.configurationExportDidDismiss(presentation.id) }) {
                ConfigurationExportView(store: store, session: session, presentation: presentation)
                    .onAppear { session.configurationExportDidAppear(presentation.id) }
            }
            .onAppear {
                if !presentation.invalidated { isPresented = true }
                else { session.configurationExportDidDismiss(presentation.id) }
            }
            .onChange(of: presentation.invalidated) { _, value in if value { isPresented = false } }
    }
}

struct ConfigurationExportView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var presentation: ConfigurationExportPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Export configuration definitions")).font(.title2.bold())
            Text(L("Review saved definitions and preferences before saving JSON. Prompts, snippets, command arguments, aliases, URLs and local resource descriptions may contain private information. This is not an anonymous export.")).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(L("Keychain values, environment values, MCP secret references, authorization, folder bookmarks and all history are excluded. Required local fields and omitted dependencies are listed in the file. Import is not available yet.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [.init(.flexible(), alignment: .leading), .init(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(ConfigurationExportSection.allCases, id: \.self) { section in
                    Toggle(section.title, isOn: Binding(get: { presentation.sections.contains(section) }, set: { presentation.setSection(section, selected: $0) }))
                        .toggleStyle(.checkbox).disabled(presentation.isSaving)
                }
            }
            HStack {
                Text(L("JSON preview")).font(.headline)
                Spacer()
                if presentation.isCapturing { ProgressView().controlSize(.small).accessibilityLabel(L("Preparing configuration preview")) }
                Button(L("Update preview")) { session.refreshConfigurationExport(presentation.id, in: store) }
                    .disabled(presentation.isSaving || presentation.isCapturing || presentation.sections.isEmpty)
            }
            if let snapshot = presentation.snapshot {
                Text(L("Definitions") + ": \(snapshot.definitionCount) · " + L("External resources") + ": \(snapshot.externalReferenceCount) · " + L("Required local fields") + ": \(snapshot.requiredLocalFieldCount) · " + L("Omitted dependencies") + ": \(snapshot.unselectedDependencyCount)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ReadOnlyTextPreview(text: snapshot.preview, accessibilityLabel: L("Configuration definitions JSON preview"), monospaced: true)
                    .frame(height: 250).modifier(KDReadingSurface())
            } else {
                Text(L("Update the preview to review the exact file before saving.")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100).modifier(KDReadingSurface())
            }
            if !presentation.previewIsCurrent && presentation.snapshot != nil {
                Text(L("Your choices changed. Update the preview before saving.")).font(.caption).foregroundStyle(.secondary)
            }
            if !presentation.notice.rendered().isEmpty { KDInlineNotice(presentation.notice.rendered()) }
            HStack {
                Button(L("Close")) { session.closeConfigurationExport(presentation.id) }.keyboardShortcut(.cancelAction).disabled(presentation.isSaving)
                Spacer()
                if presentation.isSaving { ProgressView().controlSize(.small) }
                Button(L("Save JSON…")) { presentation.beginSave() }.disabled(!presentation.canSave)
            }
            if let attempt = presentation.saveAttempt {
                ConfigurationExportSavePanel(attempt: attempt) { outcome in
                    session.finishConfigurationExportSave(presentation.id, attemptID: attempt.id, outcome: outcome)
                }.id(attempt.id)
            }
        }.padding(24).frame(width: 720).interactiveDismissDisabled(presentation.isSaving)
    }
}

private struct ConfigurationExportSavePanel: View {
    let attempt: ConfigurationExportSaveAttempt
    let finish: (ConfigurationExportSaveOutcome) -> Void
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .fileExporter(isPresented: $isPresented, document: SettingsSummaryDocument(data: attempt.snapshot.data), contentTypes: [.json],
                defaultFilename: "KeyDock-configuration-definitions", onCompletion: { result in
                    switch result { case .success: finish(.saved); case .failure: finish(.failed) }
                }, onCancellation: { finish(.cancelled) })
            .onAppear { isPresented = true }
    }
}
