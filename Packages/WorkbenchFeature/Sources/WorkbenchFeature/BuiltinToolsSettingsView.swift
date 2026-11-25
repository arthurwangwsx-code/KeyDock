import SwiftUI

struct BuiltinToolsSettingsContent: View {
    @ObservedObject var store: WorkbenchModel
    var body: some View {
        Section(L("Built-in tools")) {
            ForEach(store.contributionPresentations) { tool in
                Toggle(isOn:Binding(get:{ store.isContributionEnabled(tool.id) },set:{ store.setContributionEnabled($0,id:tool.id) })) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(tool.title).fontWeight(.medium)
                        Text(tool.detail).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,6)
                }.accessibilityLabel(tool.title).accessibilityHint(tool.detail)
            }
        }
        Section {
            Text(L("Turning a tool off stops new runs and removes its search results and active shortcuts. Saved definitions, folders, aliases, favorites and shortcut preferences are kept.")).font(.callout)
            Text(L("Commands, workflows and agents that have already started keep their original settings and permissions. Stop them in Tasks if needed. Enabling a tool does not give agents access to it.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BuiltinToolDisabledContent: View {
    @ObservedObject var store: WorkbenchModel
    var body: some View {
        HStack {
            Text(L("This tool is turned off. Saved settings are kept.")).foregroundStyle(.secondary)
            Spacer()
            Button(L("Manage built-in tools")) { store.onOpenSettings?(.tools) }
        }
    }
}
