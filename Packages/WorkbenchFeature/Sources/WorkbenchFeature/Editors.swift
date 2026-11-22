import AppKit
import SwiftUI
import ExecutionCore
import MacAdapters

struct CommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: SavedCommand
    @State private var arguments = "[]"
    @State private var environment = "{}"
    @State private var error = ""
    let onSave: (SavedCommand) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Review command")).font(.title2.bold())
            Form {
                TextField(L("Name"), text: $command.name)
                TextField(L("Executable (absolute path)"), text: $command.executable)
                TextField(L("Working directory"), text: $command.workingDirectory)
                TextField(L("Arguments (JSON array)"), text: $arguments)
                TextField(L("Environment (JSON object)"), text: $environment)
                TextField(L("Timeout in seconds"), value: $command.timeout, format: .number)
                Toggle(L("Interactive: open in Terminal"), isOn: $command.interactive)
                Toggle(L("Explicit shell mode"), isOn: $command.shellMode)
            }
            Text(L("Arguments are passed individually. For shell pipelines, explicitly choose an interpreter and its arguments. Environment values are saved locally; avoid putting secrets here.")).font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack { Button(L("Cancel")) { dismiss() }; Spacer(); Button(L("Save command")) { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 600)
        .onAppear {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            arguments = (try? String(data: encoder.encode(command.arguments), encoding: .utf8)) ?? "[]"
            environment = (try? String(data: encoder.encode(command.environment), encoding: .utf8)) ?? "{}"
        }
    }
    private func save() {
        do {
            command.arguments = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
            command.environment = try JSONDecoder().decode([String: String].self, from: Data(environment.utf8))
            guard !command.name.isEmpty, command.executable.hasPrefix("/"), command.workingDirectory.hasPrefix("/"), command.timeout > 0, command.timeout <= 86400, command.timeout.isFinite else { error = L("Check name, absolute paths and timeout"); return }
            onSave(command); dismiss()
        } catch { self.error = L("Arguments and environment must be valid JSON") }
    }
}

struct AIActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var action: AIActionPreset
    var onRecording: (Bool) -> Void = { _ in }
    let onSave: (AIActionPreset) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("AI action")).font(.title2.bold())
            TextField(L("Name"), text: Binding(get: { action.displayName }, set: { if $0 != action.displayName { action.name = $0; action.builtinKey = nil } }))
            Picker(L("Input source"), selection: $action.input) {
                Text(L("Selected text")).tag(AIInputSource.selection)
                Text(L("Current clipboard")).tag(AIInputSource.clipboard)
                Text(L("Manual input")).tag(AIInputSource.manual)
            }
            Picker(L("Output"), selection: $action.output) {
                Text(L("Show result")).tag(AIOutputMode.display)
                Text(L("Copy result")).tag(AIOutputMode.copy)
            }
            TextField(L("Model override (optional)"), text: $action.modelOverride)
            Text(L("Prompt")).font(.headline)
            TextEditor(text: $action.prompt).frame(height: 160).border(.quaternary)
            HStack { Text(L("Shortcut")); HotkeyRecorder(binding: $action.shortcut, onRecording: onRecording); Spacer() }
            Text(L("This shortcut sends only the configured input to your selected API. Replacement is a separate action.")).font(.caption).foregroundStyle(.secondary)
            HStack { Button(L("Cancel")) { dismiss() }; Spacer(); Button(L("Save action")) { onSave(action); dismiss() }.buttonStyle(.borderedProminent).disabled(action.name.isEmpty || action.prompt.isEmpty) }
        }.padding(24).frame(width: 560)
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var binding: HotkeyBinding?
    var onRecording: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton(); button.bezelStyle = .rounded
        button.onChange = { binding = $0 }; button.onRecording = onRecording; button.update(binding)
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) { button.onChange = { binding = $0 }; button.onRecording = onRecording; if !button.recording { button.update(binding) } }
}

@MainActor final class ShortcutButton: NSButton {
    var recording = false
    var onChange: ((HotkeyBinding?) -> Void)?
    var onRecording: (Bool) -> Void = { _ in }
    private var currentBinding: HotkeyBinding?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); target = self; action = #selector(startRecording); setAccessibilityLabel(L("Record shortcut")) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ binding: HotkeyBinding?) { currentBinding = binding; title = binding?.display ?? L("Record shortcut") }
    @objc private func startRecording() { recording = true; onRecording(true); title = L("Press shortcut · Esc cancel · Delete clear"); window?.makeFirstResponder(self) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
    private func finishRecording() {
        guard recording else { return }
        recording = false; update(currentBinding); onRecording(false)
    }
    override func resignFirstResponder() -> Bool { finishRecording(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { finishRecording() }; super.viewWillMove(toWindow: newWindow) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finishRecording(); return }
        if event.keyCode == 51 { currentBinding = nil; onChange?(nil); finishRecording(); return }
        let next = HotkeyBinding.from(event)
        guard next.modifiers != 0 else { NSSound.beep(); return }
        currentBinding = next; onChange?(next); finishRecording()
    }
}
