import SwiftUI
import MacAdapters

struct SettingsView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var exclusions = ""
    @State private var endpoint = ""
    @State private var modelName = ""
    @State private var localHTTP = false
    @State private var tokenParameter = "max_completion_tokens"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(L("Launcher & permissions")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(L("Global shortcut")); HotkeyRecorder(binding: Binding(get: { model.configuration.launcherShortcut }, set: { model.configuration.launcherShortcut = $0; model.save(); model.onShortcutConfigurationChanged?() }), onRecording: { model.onShortcutRecordingChanged?($0) }); Spacer() }
                        HStack { Image(systemName: model.desktop.accessibilityGranted ? "checkmark.circle.fill" : "lock"); Text(model.desktop.accessibilityGranted ? L("Accessibility enabled") : L("Accessibility required for windows and selected text")); Spacer(); Button(L("Enable Accessibility")) { model.requestAccessibility() } }
                        Text(L("Application search works without Accessibility. Screen recording is not required for window-title search.")).font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox(L("Custom compatible AI API")) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(L("Full chat completions endpoint"), text: $endpoint).textFieldStyle(.roundedBorder)
                        TextField(L("Model name"), text: $modelName).textFieldStyle(.roundedBorder)
                        SecureField(model.hasStoredKey ? L("Key stored · leave blank to keep") : L("API key"), text: $model.apiKeyDraft).textFieldStyle(.roundedBorder)
                        Picker(L("Token limit parameter"), selection: $tokenParameter) {
                            Text("max_completion_tokens").tag("max_completion_tokens")
                            Text("max_tokens").tag("max_tokens")
                        }
                        Toggle(L("Allow HTTP for localhost only"), isOn: $localHTTP)
                        Text(L("Requests go directly to this endpoint. Input is sent only when an AI action runs. Keys are stored in Keychain, never in configuration or logs.")).font(.caption).foregroundStyle(.secondary)
                        HStack { Button(L("Save API configuration")) { model.saveAPIConfiguration(endpoint: endpoint, modelName: modelName, localHTTP: localHTTP, tokenParameter: tokenParameter) }; Button(L("Remove API key"), role: .destructive) { model.removeCredential() } }
                    }.padding(8)
                }
                GroupBox(L("Clipboard privacy")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L("Record clipboard"), isOn: $model.configuration.clipboardEnabled).onChange(of: model.configuration.clipboardEnabled) { _, _ in model.save() }
                        Text(L("Text only · 24 hours · 500 items · 32 MiB total. Pinned items stay until removed. Concealed and transient types are skipped; some applications do not mark secrets.")).font(.caption).foregroundStyle(.secondary)
                        Text(L("Excluded application bundle IDs (one per line)"))
                        TextEditor(text: $exclusions).font(.system(.caption, design: .monospaced)).frame(height: 75).border(.quaternary)
                        Button(L("Save exclusions")) { model.configuration.clipboardExclusions = exclusions.split(whereSeparator: \.isNewline).map(String.init); model.save() }
                    }.padding(8)
                }
                GroupBox(L("About KeyDock")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Internal preview · macOS 14+ · Local data, no product telemetry"))
                        Link("arthur.wang.wsx@gmail.com", destination: URL(string: "mailto:arthur.wang.wsx@gmail.com")!)
                        Text(L("Support, feedback and privacy requests")).font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }.onAppear {
            endpoint = model.configuration.endpoint; modelName = model.configuration.model
            localHTTP = model.configuration.localHTTP; tokenParameter = model.configuration.tokenLimitParameter
            exclusions = model.configuration.clipboardExclusions.joined(separator: "\n"); model.checkCredential() }
    }
}
