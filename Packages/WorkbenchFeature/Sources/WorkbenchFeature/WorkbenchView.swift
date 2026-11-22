import AppKit
import SwiftUI
import CommandCore
import ExecutionCore
import MacAdapters

public struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var clipboardQuery = ""
    @State private var editingAction: AIActionPreset?
    @State private var confirmClear = false
    public init(model: WorkbenchModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command.square.fill").font(.system(size: 27)).foregroundStyle(.tint)
                Text("KeyDock").font(.title2.bold())
                Text(L("Your keyboard workspace")).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if model.tasks.contains(where: \.isRunning) { ProgressView().controlSize(.small); Text("\(model.tasks.filter(\.isRunning).count)").monospacedDigit() }
                Text(model.configuration.launcherShortcut?.display ?? "").font(.caption.monospaced()).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }.padding(18)
            HStack(spacing: 6) {
                ForEach(WorkbenchSection.allCases, id: \.self) { section in
                    Button { model.section = section } label: {
                        Label(sectionLabel(section), systemImage: sectionIcon(section)).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(model.section == section ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityLabel(sectionLabel(section))
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            Group {
                switch model.section {
                case .search: search
                case .clipboard: clipboard
                case .commands: commands
                case .ai: aiWorkspace
                case .tasks: taskList
                case .settings: SettingsView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.message.isEmpty {
                HStack { Image(systemName: "info.circle"); Text(model.message).font(.caption).textSelection(.enabled); Spacer(); Button { model.message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(10).background(.yellow.opacity(0.09))
            }
            Divider()
            HStack { Text(L("↑↓ Select    ↩ Open    Esc Close")).font(.caption); Spacer(); Text(L("Local tools · Explicit AI context")).font(.caption) }.foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(.regularMaterial)
        .sheet(item: $model.commandDraft) { CommandEditor(command: $0) { model.saveCommand($0) } }
        .sheet(item: $editingAction) { action in AIActionEditor(action: action, onRecording: { model.onShortcutRecordingChanged?($0) }) { model.saveAction($0) } }
    }
    private var search: some View {
        VStack(spacing: 0) {
            SearchInput(text: $model.query, focusRequest: model.searchFocusRequest, placeholder: L("Search applications, windows and actions…"), onMove: model.moveSelection, onSubmit: model.executeSelection, onCancel: { model.onDismiss?(true) })
                .frame(height: 44).padding(14)
            Divider()
            HSplitView {
                ScrollViewReader { proxy in
                    List(selection: $model.selectedID) {
                        ForEach(model.results) { item in
                            HStack(spacing: 10) {
                                Image(systemName: icon(item.kind)).frame(width: 24).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) { Text(item.title).lineLimit(1); Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer()
                                if model.configuration.preferences.favorites.contains(item.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                                if let alias = model.configuration.preferences.aliases[item.id], !alias.isEmpty { Text(alias).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4).tag(item.id).id(item.id)
                                .contentShape(Rectangle()).onTapGesture(count: 2) { model.execute(item) }
                        }
                    }.listStyle(.inset).onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }.frame(minWidth: 420)
                VStack(alignment: .leading, spacing: 14) {
                    if let item = model.results.first(where: { $0.id == model.selectedID }) {
                        Image(systemName: icon(item.kind)).font(.system(size: 34)).foregroundStyle(.tint)
                        Text(item.title).font(.title3.bold()).textSelection(.enabled)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(L("Open")) { model.execute(item) }.buttonStyle(.borderedProminent)
                        Button(model.configuration.preferences.favorites.contains(item.id) ? L("Remove favorite") : L("Add favorite")) { model.toggleFavorite(item) }
                        TextField(L("Search alias"), text: $model.aliasDraft).textFieldStyle(.roundedBorder)
                        Button(L("Save alias")) { model.setAlias(model.aliasDraft, for: item.id) }
                        Text(L("Shortcut")).font(.caption).foregroundStyle(.secondary)
                        HotkeyRecorder(binding: Binding(get: { model.shortcut(for: item.id) }, set: { model.setShortcut($0, for: item.id) }), onRecording: { model.onShortcutRecordingChanged?($0) })
                    } else { Text(L("Type to find your next action")).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(20).frame(minWidth: 240, idealWidth: 275, maxWidth: 320)
                    .onChange(of: model.selectedID) { _, id in model.aliasDraft = id.flatMap { model.configuration.preferences.aliases[$0] } ?? "" }
            }
        }
    }
    private var clipboard: some View {
        VStack {
            HStack {
                TextField(L("Search clipboard history"), text: $clipboardQuery).textFieldStyle(.roundedBorder).onChange(of: clipboardQuery) { _, q in model.refreshClipboard(query: q) }
                Toggle(L("Record clipboard"), isOn: $model.configuration.clipboardEnabled).toggleStyle(.switch).onChange(of: model.configuration.clipboardEnabled) { _, _ in model.save() }
                Button(L("Clear all"), role: .destructive) { confirmClear = true }
            }.padding(16)
            if model.clipboardEntries.isEmpty {
                ContentUnavailableView(L("No clipboard items"), systemImage: "clipboard", description: Text(L("Recording is optional. Sensitive marked content is skipped.")))
            } else {
                List(model.clipboardEntries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) { Text(entry.text).lineLimit(4).textSelection(.enabled); Text(entry.createdAt, style: .time).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { model.pin(entry) } label: { Image(systemName: entry.pinned ? "pin.fill" : "pin") }.help(L("Pin item"))
                        Button(L("Copy")) { ClipboardMonitor.copy(entry.text) }
                        Button { model.delete(entry) } label: { Image(systemName: "trash") }.help(L("Delete"))
                    }.padding(.vertical, 6)
                }
            }
        }.onAppear { model.refreshClipboard(query: clipboardQuery) }
            .confirmationDialog(L("Delete all clipboard history?"), isPresented: $confirmClear) { Button(L("Clear all"), role: .destructive) { model.clearClipboard() } }
    }
    private var commands: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L("Saved commands")).font(.title3.bold()); Spacer(); Button(L("New command")) { model.commandDraft = SavedCommand(name: "", executable: "/usr/bin/printf") } }
            if model.configuration.savedCommands.isEmpty { ContentUnavailableView(L("Create a reusable command"), systemImage: "terminal", description: Text(L("Save executable, arguments and working directory. Shell mode is explicit."))) }
            List(model.configuration.savedCommands) { command in
                HStack {
                    VStack(alignment: .leading) { Text(command.name); Text(command.executable + " " + command.arguments.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer(); Button(L("Edit")) { model.commandDraft = command }
                    Button(L("Run")) { model.runCommand(command) }
                    Button { model.configuration.savedCommands.removeAll { $0.id == command.id }; model.save() } label: { Image(systemName: "trash") }.help(L("Delete"))
                }.accessibilityElement(children: .contain)
                .accessibilityAction(named: Text(L("Run"))) { model.runCommand(command) }
            }
        }.padding(18)
    }
    private var aiWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(L("AI action"), selection: Binding(get: { model.activeAIActionID }, set: { model.activeAIActionID = $0; if let action = currentAction { model.prepareInput(action) } })) {
                    Text(L("Choose action")).tag(Optional<UUID>.none)
                    ForEach(model.configuration.aiActions) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 300)
                Button(L("Edit")) { editingAction = currentAction }.disabled(currentAction == nil)
                Button(L("New action")) { editingAction = AIActionPreset(name: "", prompt: "") }
                Spacer()
                Button(L("Read-only agent")) { model.runReadOnlyAgent() }.disabled(model.aiInput.isEmpty)
                Button(L("Suggest CLI")) { model.generateCommandProposal() }.disabled(model.aiInput.isEmpty)
            }
            HStack { Text(L("Input")).font(.headline); Spacer(); Text(model.target?.applicationName ?? L("Manual input")).font(.caption).foregroundStyle(.secondary) }
            TextEditor(text: Binding(get: { model.aiInput }, set: { model.aiInput = $0; model.inputSourceIsSelection = false })).font(.body).frame(minHeight: 90, maxHeight: 150).border(.quaternary)
            HStack {
                Button(L("Use current selection")) { model.aiInput = model.target?.selectedText ?? ""; model.inputSourceIsSelection = true }
                Button(L("Use clipboard")) { model.useClipboardInput() }
                Spacer()
                Button(L("Run")) { if let action = currentAction { model.runAI(action: action) } }.buttonStyle(.borderedProminent).disabled(currentAction == nil || model.aiInput.isEmpty)
            }
            Divider()
            HStack { Text(L("Result")).font(.headline); Spacer(); Button(L("Copy")) { model.copyResult() }.disabled(model.aiResult.isEmpty); Button(L("Replace original selection")) { model.replaceResult() }.disabled(model.aiResult.isEmpty || model.resultTarget == nil) }
            ScrollView { Text(model.aiResult.isEmpty ? L("Results appear here. No input is sent until you run an action.") : model.aiResult).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10) }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }.padding(18)
    }
    private var currentAction: AIActionPreset? { model.configuration.aiActions.first { $0.id == model.activeAIActionID } }
    private var taskList: some View {
        HSplitView {
            List(selection: $model.selectedTaskID) {
                ForEach(model.tasks) { task in
                    VStack(alignment: .leading, spacing: 4) { HStack { Text(task.title).lineLimit(1); Spacer(); if task.isRunning { ProgressView().controlSize(.small) } }; Text(task.state).font(.caption).foregroundStyle(.secondary) }.tag(task.id)
                }
            }.frame(minWidth: 260, idealWidth: 290, maxWidth: 350)
            VStack(alignment: .leading) {
                if let task = model.tasks.first(where: { $0.id == model.selectedTaskID }) {
                    HStack { Text(task.title).font(.headline); Spacer(); if task.isRunning { Button(L("Cancel")) { model.cancelTask(task.id) } } }
                    Text(task.state).font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(task.output).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    if !task.output.isEmpty { Button(L("Explain with AI")) { model.aiInput = task.output; model.inputSourceIsSelection = false; model.section = .ai; model.activeAIActionID = model.configuration.aiActions.last?.id } }
                } else { ContentUnavailableView(L("Your tasks stay here"), systemImage: "list.bullet.rectangle", description: Text(L("Closing the launcher does not stop running tasks."))) }
            }.padding(18).frame(maxWidth: .infinity)
        }
    }
    private func icon(_ kind: CommandKind) -> String { switch kind { case .application: "app"; case .window: "macwindow"; case .command: "terminal"; case .clipboard: "clipboard"; case .ai: "sparkles"; case .utility: "square.grid.2x2" } }
    private func sectionLabel(_ section: WorkbenchSection) -> String { switch section { case .search: L("Search"); case .clipboard: L("Clipboard"); case .commands: L("Commands"); case .ai: L("AI"); case .tasks: L("Tasks"); case .settings: L("Settings") } }
    private func sectionIcon(_ section: WorkbenchSection) -> String { switch section { case .search: "magnifyingglass"; case .clipboard: "clipboard"; case .commands: "terminal"; case .ai: "sparkles"; case .tasks: "list.bullet.rectangle"; case .settings: "gearshape" } }
}
