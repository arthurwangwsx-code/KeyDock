import SwiftUI
import CommandCore
import KeyDockUI

struct DesktopWorkspacesSettingsView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @State private var removing: SavedDesktopWorkspace?
    var body: some View {
        Section(L("Desktop workspaces")) {
            Text(L("Apply an ordered group of applications and window layouts, or assign a direct shortcut. Saving a definition does not launch or move applications.")).font(.callout).foregroundStyle(.secondary)
            if !store.desktopWorkspacesWritable { KDInlineNotice(L("Desktop workspaces are read-only. Existing data has been preserved.")) }
            ForEach(store.desktopWorkspaces) { value in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.3.group").foregroundStyle(.tint).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(value.name).fontWeight(.medium).lineLimit(2)
                            Text(L("Applications") + ": \(value.entries.count) · " + L("Saved version") + ": \(value.revision)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack {
                        if let item = store.catalog.first(where: { $0.id == value.commandID }) {
                            Button(L("Apply workspace")) { store.execute(item) }.disabled(store.isShuttingDown || store.tasks.contains(where: { $0.desktopWorkspaceID == value.id && $0.isRunning }))
                            Button(L("Shortcut")) { store.onOpenShortcutSettings?(item) }
                        }
                        Spacer()
                        Button(L("Edit")) { session.beginDesktopWorkspace(value, in: store) }.disabled(!store.desktopWorkspacesWritable)
                        Button(L("Remove"), role: .destructive) { removing = value }.accessibilityLabel(L("Remove") + " " + value.name).disabled(!store.desktopWorkspacesWritable)
                    }
                }.padding(.vertical, 7)
                if let task = store.tasks.first(where: { $0.desktopWorkspaceID == value.id }) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) { Text(task.state).font(.caption.weight(.medium)); if !task.notice.isEmpty { Text(task.notice).font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                        if task.canCancel { Button(L("Stop")) { store.cancelTask(task.id) } }
                        Button(L("View result")) { store.onOpenWorkspace?(.tasks(task.id)) }.disabled(task.isRunning)
                    }.padding(.bottom, 6)
                }
            }
            if store.desktopWorkspaces.isEmpty { Text(L("No desktop workspaces yet")).foregroundStyle(.secondary) }
            Button { session.beginDesktopWorkspace(in: store) } label: { Label(L("Add desktop workspace"), systemImage: "plus") }
                .disabled(!store.desktopWorkspacesWritable || store.desktopWorkspaces.count >= DesktopWorkspaceArchive.maximumWorkspaces)
        }
        .confirmationDialog(L("Remove this workspace definition?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { value in
            Button(L("Remove"), role: .destructive) { store.removeDesktopWorkspace(value); removing = nil }
        }
    }
}

struct DesktopWorkspaceEditorView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var draft: DesktopWorkspaceEditorDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Desktop workspace definition")).font(.title2.weight(.semibold))
            TextField(L("Name"), text: $draft.name).textFieldStyle(.roundedBorder)
            Text(L("Each target uses the application's focused window at invocation. Window titles and selected text are not saved.")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach($draft.rows) { $row in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L("Application") + " \((draft.rows.firstIndex(where: { $0.id == row.id }) ?? 0)+1)").font(.headline)
                                Spacer()
                                Button { draft.moveRow(row.id, by: -1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel(L("Move target up")).disabled(draft.rows.first?.id == row.id)
                                Button { draft.moveRow(row.id, by: 1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel(L("Move target down")).disabled(draft.rows.last?.id == row.id)
                                Button(L("Remove"), role: .destructive) { draft.removeRow(row.id) }.accessibilityLabel(L("Remove application target") + " \((draft.rows.firstIndex(where: { $0.id == row.id }) ?? 0)+1)")
                            }
                            Picker(L("Application"), selection: $row.applicationID) {
                                if !store.configurableApplications.contains(where: { $0.id == row.applicationID }) {
                                    Text(row.applicationID.isEmpty ? L("Choose an application") : L("Application unavailable") + ": " + row.applicationID).tag(row.applicationID)
                                }
                                ForEach(store.configurableApplications.filter { app in app.id == row.applicationID || !draft.rows.contains(where: { $0.applicationID == app.id }) }) { app in Text(app.title).tag(app.id) }
                            }
                            Picker(L("Window layout"), selection: $row.layout) { ForEach(DesktopWorkspaceEntry.allowedLayouts, id: \.rawValue) { layout in Text(L(layout.titleKey)).tag(layout) } }
                            Picker(L("Target screen"), selection: $row.display) { ForEach(DesktopWorkspaceDisplayPolicy.allCases, id: \.rawValue) { Text(workspaceDisplayTitle($0)).tag($0) } }
                            Picker(L("Missing application"), selection: $row.missingApplication) { ForEach(DesktopWorkspaceMissingApplicationPolicy.allCases, id: \.rawValue) { Text(workspaceMissingApplicationTitle($0)).tag($0) } }
                        }.padding(14).modifier(KDReadingSurface())
                    }
                    Button { draft.addRow() } label: { Label(L("Add application target"), systemImage: "plus") }.disabled(draft.rows.count >= SavedDesktopWorkspace.maximumEntries)
                }.padding(.vertical, 2)
            }
            if !draft.notice.rendered().isEmpty { KDInlineNotice(draft.notice.rendered()) }
            HStack {
                Button(L("Cancel")) { session.cancelDesktopWorkspaceEdit(draft.id) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Save definition")) { store.performUserInputAction { session.saveDesktopWorkspaceEdit(draft.id, in: store) } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!store.desktopWorkspacesWritable || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.rows.isEmpty || draft.rows.contains(where: { $0.applicationID.isEmpty }))
            }
        }.padding(24).frame(width: 620, height: 590)
    }
}
