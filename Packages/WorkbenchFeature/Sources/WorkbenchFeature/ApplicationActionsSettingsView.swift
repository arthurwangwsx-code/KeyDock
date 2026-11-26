import SwiftUI
import CommandCore
import KeyDockUI

struct ApplicationActionsSettingsView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    private struct EditorInput: Identifiable { let id = UUID(); let initial: SavedApplicationAction? }
    @State private var editor: EditorInput?
    var body: some View {
        Section(L("Application actions")) {
            Text(L("Create a named action for an application, then give it an alias or shortcut. Application shortcuts run directly without opening KeyDock.")).font(.callout).foregroundStyle(.secondary)
            if !store.applicationActionsWritable {
                KDInlineNotice(L("Application actions are read-only because their file could not be loaded or safely saved. Existing data has not been reset."))
            }
            ForEach(store.applicationActions) { action in
                HStack(spacing: 12) {
                    Image(systemName: action.behavior == .requestQuit ? "power" : "app.badge").foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.name).fontWeight(.medium)
                        Text(applicationTitle(action.applicationID) + " · " + L(action.behavior.titleKey)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let item = store.catalog.first(where: { $0.id == "application-action." + action.id.uuidString }) {
                        Button(L("Shortcut & alias")) { store.onOpenShortcutSettings?(item) }
                    }
                    Button(L("Edit")) { editor = EditorInput(initial: action) }.disabled(!store.applicationActionsWritable || !session.canBeginSavedItemEditor)
                    Button(L("Delete"), role: .destructive) { session.prepareRemoval(.applicationAction(action.id), in: store) }.disabled(!store.applicationActionsWritable || !session.canBeginSavedItemEditor)
                }.padding(.vertical, 6)
            }
            if store.applicationActions.isEmpty { Text(L("No application actions yet")).foregroundStyle(.secondary) }
            Button { editor = EditorInput(initial: nil) } label: { Label(L("Add application action"), systemImage: "plus") }
                .disabled(!session.canBeginSavedItemEditor || !store.applicationActionsWritable || store.applicationActions.count >= ApplicationActionArchive.maximumActions || store.configurableApplications.isEmpty)
        }
        .sheet(item: $editor) { input in ApplicationActionEditor(store: store, initial: input.initial) }
        Section {
            Text(L("Normal quit never force-quits or dismisses save dialogs. Show all windows brings windows forward; minimized windows and Spaces remain controlled by macOS.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func applicationTitle(_ id: String) -> String {
        store.configurableApplications.first(where: { $0.id == id })?.title ?? L("Application unavailable")
    }
}

private struct ApplicationActionEditor: View {
    @ObservedObject var store: WorkbenchModel
    let initial: SavedApplicationAction?
    private let actionID: UUID
    private let expectedRevision: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var applicationID: String
    @State private var behavior: ApplicationBehavior
    @State private var invalid = false
    init(store: WorkbenchModel, initial: SavedApplicationAction?) {
        self.store = store; self.initial = initial
        actionID = initial?.id ?? UUID()
        expectedRevision = initial.flatMap { store.applicationActionRevision($0) }
        _name = State(initialValue: initial?.name ?? "")
        _applicationID = State(initialValue: initial?.applicationID ?? "")
        _behavior = State(initialValue: initial?.behavior ?? .toggleVisibility)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("Application action")).font(.title2.weight(.semibold))
            Form {
                TextField(L("Name"), text: $name)
                Picker(L("Application"), selection: $applicationID) {
                    if !store.configurableApplications.contains(where: { $0.id == applicationID }) { Text(applicationID.isEmpty ? L("Choose an application") : L("Application unavailable")).tag(applicationID) }
                    ForEach(store.configurableApplications) { Text($0.title).tag($0.id) }
                }
                Picker(L("Action"), selection: $behavior) { ForEach(ApplicationBehavior.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) } }
            }.formStyle(.grouped)
            if invalid || !store.settingsNotice.isEmpty { KDInlineNotice(invalid ? L("Choose an available application and enter a short name.") : store.settingsNotice) }
            HStack {
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Save")) {
                    guard store.configurableApplications.contains(where: { $0.id == applicationID }),
                          let action = try? SavedApplicationAction(id: actionID, name: name, applicationID: applicationID, behavior: behavior),
                          initial == nil || expectedRevision != nil else { invalid = true; return }
                    invalid = false
                    if store.saveApplicationAction(action, expectedRevision: expectedRevision, creating: initial == nil) { dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!store.applicationActionsWritable)
            }
        }.padding(24).frame(width: 540, height: 390)
    }
}
