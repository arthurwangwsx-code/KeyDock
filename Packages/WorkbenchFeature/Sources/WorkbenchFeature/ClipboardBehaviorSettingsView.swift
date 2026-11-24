import SwiftUI
import CommandCore

struct ClipboardBehaviorSettingsView: View {
    @ObservedObject var preferences: ClipboardPanelPreferences
    var body: some View {
        Section(L("History panel behavior")) {
            Picker(L("Return key action"), selection: $preferences.primaryAction) {
                ForEach(ClipboardPrimaryAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(L("Merge separator"), selection: $preferences.separator) {
                ForEach(ClipboardSeparator.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(L("Command-Return performs the other action. Shift-Return adds or removes the current item from the ordered merge selection. Recording remains optional.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
