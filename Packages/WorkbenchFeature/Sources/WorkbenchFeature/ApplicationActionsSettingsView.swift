import SwiftUI
import CommandCore
import KeyDockUI

/// 点击时冻结；View重建不重取当前epoch，也不为未保存的新动作另造ID。
@MainActor final class ApplicationActionEditorDraft: ObservableObject, Identifiable {
    let id = UUID()
    let initial: SavedApplicationAction?
    let expectedRevision: String?
    @Published var name: String
    @Published var applicationID: String
    @Published var behavior: ApplicationBehavior
    @Published var closed = false
    var appeared = false
    var actionID: UUID { initial?.id ?? id }
    @MainActor init(initial: SavedApplicationAction?, store: WorkbenchModel) {
        self.initial = initial; expectedRevision = initial.flatMap { store.applicationActionRevision($0) }
        name = initial?.name ?? ""; applicationID = initial?.applicationID ?? ""; behavior = initial?.behavior ?? .toggleVisibility
    }
}

extension SettingsSession {
    func beginApplicationAction(_ initial: SavedApplicationAction?, in store: WorkbenchModel) {
        guard canBeginSavedItemEditor, store.applicationActionsWritable, !store.isDesktopReview,
              initial.map({ store.applicationActions.contains($0) }) ?? true else { return }
        applicationActionEditor = .init(initial: initial, store: store)
    }
    func closeApplicationActionEditor(_ id: UUID) {
        guard let draft = applicationActionEditor, draft.id == id else { return }
        draft.closed = true
        if draft.appeared { applicationActionEditorDismissing = true }
        else { applicationActionEditor = nil; applicationActionEditorDismissing = false }
    }
    func applicationActionEditorDidAppear(_ id: UUID) {
        if let draft = applicationActionEditor, draft.id == id, !draft.closed { draft.appeared = true }
    }
    func applicationActionEditorDidDismiss(_ id: UUID) {
        guard applicationActionEditor?.id == id else { return }
        applicationActionEditor = nil; applicationActionEditorDismissing = false
    }
    @discardableResult func saveApplicationActionEditor(_ action: SavedApplicationAction, draft: ApplicationActionEditorDraft, in store: WorkbenchModel) -> Bool {
        guard applicationActionEditor === draft, !draft.closed, !applicationActionEditorDismissing, action.id == draft.actionID else { return false }
        guard store.saveApplicationAction(action, expectedRevision: draft.expectedRevision, creating: draft.initial == nil) else { return false }
        closeApplicationActionEditor(draft.id); return true
    }
}

struct ApplicationActionSheetHost: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var draft: ApplicationActionEditorDraft
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { isPresented && !draft.closed }, set: { value in
                if !value { session.closeApplicationActionEditor(draft.id) }; isPresented = value
            }), onDismiss: { session.applicationActionEditorDidDismiss(draft.id) }) {
                ApplicationActionEditor(store: store, session: session, draft: draft)
                    .onAppear { session.applicationActionEditorDidAppear(draft.id) }
            }
            .onAppear { if !draft.closed { isPresented = true } else { session.applicationActionEditorDidDismiss(draft.id) } }
            .onChange(of: draft.closed) { _, value in if value { isPresented = false } }
    }
}

struct ApplicationActionsSettingsView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
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
                    Button(L("Edit")) { session.beginApplicationAction(action, in: store) }.disabled(!store.applicationActionsWritable || !session.canBeginSavedItemEditor)
                    Button(L("Delete"), role: .destructive) { session.prepareRemoval(.applicationAction(action.id), in: store) }.disabled(!store.applicationActionsWritable || !session.canBeginSavedItemEditor)
                }.padding(.vertical, 6)
            }
            if store.applicationActions.isEmpty { Text(L("No application actions yet")).foregroundStyle(.secondary) }
            Button { session.beginApplicationAction(nil, in: store) } label: { Label(L("Add application action"), systemImage: "plus") }
                .disabled(!session.canBeginSavedItemEditor || !store.applicationActionsWritable || store.applicationActions.count >= ApplicationActionArchive.maximumActions || store.configurableApplications.isEmpty)
        }
        Section {
            Text(L("Normal quit never force-quits or dismisses save dialogs. Show all windows brings windows forward; minimized windows and Spaces remain controlled by macOS.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func applicationTitle(_ id: String) -> String {
        store.configurableApplications.first(where: { $0.id == id })?.title ?? L("Application unavailable")
    }
}

struct ApplicationActionEditor: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @ObservedObject var draft: ApplicationActionEditorDraft
    @State private var invalid = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("Application action")).font(.title2.weight(.semibold))
            Form {
                TextField(L("Name"), text: $draft.name)
                Picker(L("Application"), selection: $draft.applicationID) {
                    if !store.configurableApplications.contains(where: { $0.id == draft.applicationID }) { Text(draft.applicationID.isEmpty ? L("Choose an application") : L("Application unavailable")).tag(draft.applicationID) }
                    ForEach(store.configurableApplications) { Text($0.title).tag($0.id) }
                }
                Picker(L("Action"), selection: $draft.behavior) { ForEach(ApplicationBehavior.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) } }
            }.formStyle(.grouped)
            if invalid || !store.settingsNotice.isEmpty { KDInlineNotice(invalid ? L("Choose an available application and enter a short name.") : store.settingsNotice) }
            HStack {
                Button(L("Cancel")) { session.closeApplicationActionEditor(draft.id) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Save")) {
                    guard store.configurableApplications.contains(where: { $0.id == draft.applicationID }),
                          let action = try? SavedApplicationAction(id: draft.actionID, name: draft.name, applicationID: draft.applicationID, behavior: draft.behavior),
                          draft.initial == nil || draft.expectedRevision != nil else { invalid = true; return }
                    invalid = false
                    session.saveApplicationActionEditor(action, draft: draft, in: store)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!store.applicationActionsWritable || draft.closed)
            }
        }.padding(24).frame(width: 540, height: 390)
    }
}
