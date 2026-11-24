import SwiftUI
import CommandCore
import ExecutionCore
import MacAdapters
import KeyDockUI

public struct SettingsRootView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: SettingsSession
    @State private var exclusions = ""
    @State private var aliases: [String: String] = [:]
    @State private var confirmTaskClear = false
    @State private var confirmUsageClear = false
    public init(store: WorkbenchModel, session: SettingsSession) { self.store = store; self.session = session }
    public var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, id: \.self, selection: Binding<SettingsPane?>(get: { session.pane }, set: { if let value = $0 { session.pane = value } })) { pane in Label(pane.title, systemImage: pane.icon).tag(pane) }
                .id(store.configuration.language)
                .listStyle(.sidebar).navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
        } detail: {
            Form {
                if !store.settingsNotice.isEmpty { Section { KDInlineNotice(store.settingsNotice) } }
                if store.shortcutsUnavailable {
                    Section {
                        Text(L("Shortcuts are inactive. Choose another shortcut or retry registration."))
                        Button(L("Retry shortcuts")) { store.retryShortcuts() }
                    }
                }
                if !store.pendingCommandReviews.isEmpty { Section { HStack { Text(L("Command draft ready for review")); Spacer(); Button(L("Review")) { if let review = store.takeNextCommandReview() { session.reviewCommand(review.command, sourceRunID: review.id) } }.disabled(session.editedCommand != nil || session.editedAction != nil) } } }
                content
            }.formStyle(.grouped)
        }.frame(minWidth: 740, minHeight: 530).environment(\.locale, KDLocalizer.locale)
            .sheet(item: $session.editedCommand, onDismiss: { session.editedCommandSourceRunID = nil; session.editedCommandExistingID = nil }) { command in CommandEditor(command: command, failureMessage: { store.settingsNoticeMessage }) { session.saveEditedCommand($0, in: store) } }
            .sheet(item: $session.editedAction, onDismiss: { session.editedActionExistingID = nil }) { action in AIActionEditor(action: action, onRecording: { store.onShortcutRecordingChanged?($0) }, failureMessage: { store.settingsNoticeMessage }) { session.saveEditedAction($0, in: store) } }
            .sheet(item: $session.savedItemRemoval) { presentation in SavedItemRemovalView(store: store, session: session, presentation: presentation) }
            .sheet(item: $session.desktopWorkspaceEditor) { draft in DesktopWorkspaceEditorView(store: store, session: session, draft: draft) }
            .onAppear { exclusions = store.configuration.clipboardExclusions.joined(separator: "\n"); session.keyStored = store.credentialExists() }
            .confirmationDialog(L("Clear finished tasks and idle drafts?"), isPresented: $confirmTaskClear) {
                Button(L("Clear finished history"), role: .destructive) { Task { await store.clearFinishedHistory() } }
            } message: {
                Text(L("This discards finished task output, idle unsaved AI drafts and command suggestions. Running tasks are kept. Terminal commands may still be running; clearing history does not stop them. Saved commands, settings, credentials and clipboard history are kept."))
            }
            .confirmationDialog(L("Clear AI usage history?"), isPresented: $confirmUsageClear) {
                Button(L("Clear AI usage history"), role: .destructive) { Task { await store.clearAIUsageHistory() } }
            } message: {
                Text(L("This removes stored usage metadata. Running requests keep their current usage and may create new records when they finish. AI actions and API credentials are kept."))
            }
    }
    @ViewBuilder private var content: some View {
        switch session.pane {
        case .mcp: MCPSettingsContent(store:store,session:session)
        case .general:
            if !store.allowContextCapture { Section { Text(L("Isolated preview: clipboard and selected-text capture, permission requests and credential storage are disabled.")).font(.caption).foregroundStyle(.secondary) } }
            Section(L("Appearance & language")) {
                Picker(L("Language"), selection: Binding(get: { store.configuration.language }, set: { store.setLanguage($0) })) {
                    Text(L("Follow System")).tag("system"); Text("English").tag("en"); Text("简体中文").tag("zh-Hans")
                }
                Picker(L("Appearance"), selection: Binding(get: { store.configuration.appearance }, set: { store.setAppearance($0) })) {
                    Text(L("Follow System")).tag("system"); Text(L("Light")).tag("light"); Text(L("Dark")).tag("dark")
                }
            }
            Section(L("Launcher")) {
                HStack { Text(L("Global shortcut")); Spacer(); recorder(Binding(get: { store.configuration.launcherShortcut }, set: { store.setLauncherShortcut($0) })) }
                if !store.shortcutsUnavailable {
                    Label(ShortcutPlan.entries(store.configuration).isEmpty ? L("No shortcuts configured") : L("Registered with macOS"), systemImage: ShortcutPlan.entries(store.configuration).isEmpty ? "keyboard" : "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Applications")) {
                Text(L("The local application list updates automatically. Refresh it if a newly installed application is missing.")).font(.caption).foregroundStyle(.secondary)
                Button(L("Refresh application list")) { store.refreshApplications() }
                if !store.applicationIndexNotice.isEmpty { KDInlineNotice(store.applicationIndexNotice) }
            }
            Section { Text(L("Search and quick actions live in the launcher. Configuration stays here, while long tasks continue in Workspace.")).font(.caption).foregroundStyle(.secondary) }
        case .shortcuts:
            Section {
                Picker(L("Action category"), selection: $session.shortcutCategory) {
                    ForEach(ShortcutCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField(L("Find an action to customize"), text: Binding(get: { session.shortcutQuery }, set: { session.editShortcutQuery($0) }))
                Text(L("Choose Applications to assign app shortcuts. Window layouts and tools can be configured without adding favorites.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Global shortcut")) {
                HStack { Text(L("Open KeyDock")); Spacer(); recorder(Binding(get: { store.configuration.launcherShortcut }, set: { store.setLauncherShortcut($0) })) }
                HStack { Text(L("Clipboard history")); Spacer(); recorder(Binding(get: { store.shortcut(for: "utility.clipboard") }, set: { store.setShortcut($0, for: "utility.clipboard") })) }
                HStack {
                    TextField(L("Clipboard search alias"), text: Binding(get: { aliases["utility.clipboard"] ?? store.configuration.preferences.aliases["utility.clipboard"] ?? "" }, set: { aliases["utility.clipboard"] = $0 }))
                    Button(L("Save alias")) { store.setAlias(aliases["utility.clipboard"] ?? store.configuration.preferences.aliases["utility.clipboard"] ?? "", for: "utility.clipboard") }
                }.controlSize(.small)
            }
            Section(L("Actions & aliases")) {
                ForEach(shortcutItems) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(item.title).fontWeight(.medium); Spacer(); recorder(Binding(get: { store.shortcut(for: item.id) }, set: { store.setShortcut($0, for: item.id) })) }
                        HStack { TextField(L("Search alias"), text: Binding(get: { aliases[item.id] ?? store.configuration.preferences.aliases[item.id] ?? "" }, set: { aliases[item.id] = $0 })); Button(L("Save alias")) { store.setAlias(aliases[item.id] ?? store.configuration.preferences.aliases[item.id] ?? "", for: item.id) } }.controlSize(.small)
                    }.padding(.vertical, 5)
                }
            }
            if !unavailableShortcutIDs.isEmpty {
                Section(L("Unavailable actions")) {
                    ForEach(unavailableShortcutIDs, id: \.self) { id in
                        if let binding = store.configuration.commandShortcuts[id] {
                            HStack {
                                Text(unavailableActionName(id)); KDKeycap(binding.display); Spacer()
                                Button(L("Remove shortcut")) { store.setShortcut(nil, for: id) }
                            }
                        }
                    }
                }
            }
        case .aiService:
            Section(L("Connection")) {
                TextField(L("Full chat completions endpoint"), text: $session.endpoint)
                TextField(L("Model name"), text: $session.modelName)
                SecureField(session.keyStored && session.endpoint == store.configuration.endpoint ? L("Key stored · leave blank to keep") : L("API key"), text: $session.apiKey).disabled(!store.allowContextCapture)
                Picker(L("Token limit parameter"), selection: $session.tokenParameter) { Text("max_completion_tokens").tag("max_completion_tokens"); Text("max_tokens").tag("max_tokens") }
                Toggle(L("Allow HTTP for localhost only"), isOn: $session.localHTTP)
            }
            Section {
                Text(store.allowContextCapture ? L("Requests go directly to this endpoint. Input is sent only when an AI action runs. Keys are stored in Keychain, never in configuration or logs.") : L("Isolated preview: endpoints without keys can be tested. Use a regular build to store credentials.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Save API configuration")) {
                        if store.saveAPIConfiguration(endpoint: session.endpoint, modelName: session.modelName, localHTTP: session.localHTTP, tokenParameter: session.tokenParameter, apiKey: session.apiKey) { session.apiKey = ""; session.keyStored = store.credentialExists() }
                    }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button(L("Remove API key"), role: .destructive) { store.removeCredential(); session.keyStored = store.credentialExists() }.disabled(session.endpoint != store.configuration.endpoint || !session.keyStored)
                }
            }
        case .aiActions:
            Section(L("Reusable AI actions")) {
                ForEach(store.configuration.aiActions) { action in
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) { Text(action.displayName).fontWeight(.medium); Text(action.modelOverride.isEmpty ? L("Default model") : action.modelOverride).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); if let key = action.shortcut { KDKeycap(key.display) }
                        Button(L("Edit")) { session.editAction(action) }
                        Button(L("Remove"), role: .destructive) { session.prepareRemoval(.aiAction(action.id), in: store) }.accessibilityLabel(L("Remove") + " " + action.displayName)
                    }.padding(.vertical, 7)
                }
            }
            Section { Text(L("Create a translation, summary or custom prompt, then assign its own shortcut.")).font(.caption).foregroundStyle(.secondary) }
        case .applications:
            ApplicationActionsSettingsView(store: store)
        case .desktopWorkspaces:
            DesktopWorkspacesSettingsView(store: store, session: session)
        case .commands:
            Section(L("Saved commands")) {
                if store.configuration.savedCommands.isEmpty { Text(L("Create a reusable command")).foregroundStyle(.secondary) }
                ForEach(store.configuration.savedCommands) { command in
                    HStack(spacing: 12) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) { Text(command.name).fontWeight(.medium); Text(command.executable).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        Spacer(); Button(L("Edit")) { session.editCommand(command) }; Button(L("Run")) { if let current = store.configuration.savedCommands.first(where: { $0.id == command.id }) { store.runCommand(current) } }
                        Button(L("Remove"), role: .destructive) { session.prepareRemoval(.command(command.id), in: store) }.accessibilityLabel(L("Remove") + " " + command.name)
                    }.padding(.vertical, 7)
                }
            }
        case .clipboard:
            ClipboardBehaviorSettingsView(preferences: store.clipboardPreferences)
            Section(L("Clipboard history")) {
                Toggle(L("Record clipboard"), isOn: Binding(get: { store.allowContextCapture && store.configuration.clipboardEnabled }, set: { store.setClipboardRecording($0) })).disabled(!store.allowContextCapture)
                Text(L("Text only · 24 hours · 500 items · 1 MiB per item · 32 MiB of text. Pinned items count toward capacity and stay until removed. When they leave too little room, new items are skipped without deleting existing history. Concealed and transient types are skipped; some applications do not mark secrets.")).font(.caption).foregroundStyle(.secondary)
                if !store.clipboardCaptureNotice.isEmpty { KDInlineNotice(store.clipboardCaptureNotice) }
            }
            Section(L("Excluded applications")) {
                TextEditor(text: $exclusions).font(.system(size: 11, design: .monospaced)).frame(height: 110).accessibilityLabel(L("Excluded applications"))
                Button(L("Save exclusions")) { store.saveClipboardExclusions(exclusions.split(whereSeparator: \.isNewline).map(String.init)) }
            }
        case .privacy:
            Section(L("Accessibility")) {
                Label(store.desktop.accessibilityGranted ? L("Accessibility enabled") : L("Accessibility required for windows and selected text"), systemImage: store.desktop.accessibilityGranted ? "checkmark.circle" : "lock")
                Button(L("Enable Accessibility")) { store.requestAccessibility() }.disabled(!store.allowContextCapture)
                Text(L("Application search works without Accessibility. Screen recording is not required for window-title search.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Your data")) { Text(L("Local data, no product telemetry. AI actions send only their chosen input to your configured service.")).font(.callout).foregroundStyle(.secondary) }
            Section(L("Task and usage history")) {
                Text(L("KeyDock manages up to 8 tasks at once, with 200 task records, 32 AI drafts and 32 MiB of session text. Output stays in memory; after restarting, only task metadata is restored. Finished task and usage records expire after 90 days.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Clear finished history"), role: .destructive) { confirmTaskClear = true }.disabled(store.isClearingHistory)
                    if store.isClearingHistory { ProgressView().controlSize(.small) }
                }
                HStack {
                    Button(L("Clear AI usage history"), role: .destructive) { confirmUsageClear = true }.disabled(store.isClearingUsage)
                    if store.isClearingUsage { ProgressView().controlSize(.small) }
                }
            }
        case .about:
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "command.square.fill").font(.system(size: 54, weight: .light)).foregroundStyle(.tint)
                    Text("KeyDock").font(.system(size: 26, weight: .semibold))
                    Text(L("Your keyboard workspace")).font(.subheadline).foregroundStyle(.secondary)
                    Text(appVersionLabel).font(.caption).foregroundStyle(.tertiary)
                    Link("arthur.wang.wsx@gmail.com", destination: URL(string: "mailto:arthur.wang.wsx@gmail.com")!)
                    Text(L("Support, feedback and privacy requests")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
    }
    private var shortcutItems: [CommandItem] {
        session.shortcutItems(in: store.catalog, preferences: store.configuration.preferences)
    }
    private var appVersionLabel: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "KeyDockReleaseVersion") as? String {
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            return version + (build.isEmpty ? "" : " (" + build + ")")
        }
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") + " · " + L("Internal Preview")
    }
    private var unavailableShortcutIDs: [String] {
        let current = Set(store.catalog.filter { $0.kind != .window }.map(\.id))
        return store.configuration.commandShortcuts.keys.filter { !current.contains($0) }.sorted()
    }
    private func unavailableActionName(_ id: String) -> String {
        if id.hasPrefix("app.") {
            let name = URL(fileURLWithPath: String(id.dropFirst(4))).deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        return L("Unavailable action")
    }
    private func recorder(_ binding: Binding<HotkeyBinding?>) -> some View { HotkeyRecorder(binding: binding, onRecording: { store.onShortcutRecordingChanged?($0) }).fixedSize() }
}
