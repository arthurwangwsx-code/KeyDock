import SwiftUI
import UniformTypeIdentifiers
import CommandCore
import MacAdapters
import KeyDockUI

struct ToolsWorkspaceView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @State private var chooseFile = false
    @State private var confirmSnippetRemoval: UUID?
    var body: some View {
        Form {
            Section(L("Calculator")) {
                if !store.isContributionEnabled(BuiltinContributionID.calculator) { BuiltinToolDisabledContent(store:store) }
                HStack {
                    TextField(L("Arithmetic expression"),text:$session.calculatorInput).onSubmit(calculate)
                    Button(L("Calculate"),action:calculate)
                }.disabled(!store.isContributionEnabled(BuiltinContributionID.calculator))
                if !session.calculatorResult.isEmpty { Text(session.calculatorResult).font(.title2.monospaced()).textSelection(.enabled) }
                Text(L("Arithmetic only: +, −, ×, / and parentheses. No scripts or functions are executed.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Unit conversion")) {
                HStack { TextField(L("Example: 10 km to mi"),text:$session.unitInput).onSubmit(convert); Button(L("Convert"),action:convert) }.disabled(!store.isContributionEnabled(BuiltinContributionID.calculator))
                if !session.unitResult.isEmpty { Text(session.unitResult).font(.title2.monospaced()).textSelection(.enabled) }
                Text(L("Length, mass, absolute temperature and data bytes. MB and MiB use different scales. Approximate results.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Text and OCR")) {
                HStack {
                    Button(L("Choose text, PDF or image")) { chooseFile = true }.disabled(store.isClearingHistory)
                    Button(L("Capture a region")) { store.captureRegion(session:session) }.disabled(!store.allowContextCapture || store.isClearingHistory)
                    Button(L("Screen Recording settings")) { DocumentContextService.openScreenRecordingSettings() }.disabled(!store.allowContextCapture)
                }
                Text(L("OCR runs locally. Files are limited to 16 MiB, images to 20 million pixels and PDFs to 30 pages. Text is limited to 128 KiB. Nothing is sent to AI until you choose an action.")).font(.caption).foregroundStyle(.secondary)
                Text(L("One text input is kept in this session. A new import replaces it. Clear input removes its text and source; existing AI drafts and task results are kept in history.")).font(.caption).foregroundStyle(.secondary)
                if !session.toolsSourceName.isEmpty { Text(session.toolsSourceName).font(.caption).foregroundStyle(.secondary) }
                TextEditor(text:Binding(get:{session.toolsText},set:{store.editToolsInput($0,session:session)})).font(.body).frame(minHeight:140).modifier(KDReadingSurface()).accessibilityLabel(L("Imported text")).disabled(store.isClearingHistory)
                HStack {
                    ForEach(store.configuration.aiActions.prefix(3)) { action in
                        Button(action.displayName) {
                            guard let draft = store.createToolsDraft(actionID:action.id,session:session) else { return }; session.navigate(.ai(draft.id),store:store)
                        }.disabled(session.toolsText.isEmpty)
                    }
                    Spacer()
                    Button(L("Clear input")) { store.clearToolsInput(session) }
                }
            }
            Section(L("Snippets")) {
                ForEach(store.configuration.snippets) { snippet in
                    HStack {
                        Text(snippet.name).lineLimit(1); Spacer()
                        Button(L("Copy")) { store.copySnippet(snippet.id) }
                        Button(L("Edit")) { session.selectedSnippetID = snippet.id; session.snippetName = snippet.name; session.snippetText = snippet.text }
                        Button(L("Remove"),role:.destructive) { confirmSnippetRemoval = snippet.id }
                    }
                }
                TextField(L("Name"),text:$session.snippetName)
                TextEditor(text:$session.snippetText).frame(minHeight:80,maxHeight:160).modifier(KDReadingSurface()).accessibilityLabel(L("Snippet text"))
                HStack {
                    Button(L("Save snippet")) {
                        if store.saveSnippet(id:session.selectedSnippetID,name:session.snippetName,text:session.snippetText) { session.selectedSnippetID = nil; session.snippetName = ""; session.snippetText = "" }
                    }
                    Button(L("New snippet")) { session.selectedSnippetID = nil; session.snippetName = ""; session.snippetText = "" }
                }
                Text(L("Snippets are copied only when you choose them. KeyDock does not listen to your typing or expand hidden templates.")).font(.caption).foregroundStyle(.secondary)
            }
            WebAndCollectionsPanel(store:store,session:session)
            FileSearchPanel(store:store,search:session.files)
            MCPContentPanel(store:store,session:session)
        }.formStyle(.grouped)
            .fileImporter(isPresented:$chooseFile,allowedContentTypes:[.text,.pdf,.image]) { result in if case .success(let url) = result { store.importDocument(url,session:session) } }
            .confirmationDialog(L("Remove this snippet?"),isPresented:Binding(get:{confirmSnippetRemoval != nil},set:{if !$0 { confirmSnippetRemoval = nil }})) { Button(L("Remove"),role:.destructive) { if let id = confirmSnippetRemoval { store.removeSnippet(id) }; confirmSnippetRemoval = nil } }
    }
    private func convert() {
        do { session.unitResult = try store.calculate(.conversion(session.unitInput)) }
        catch { session.unitResult = L("Invalid conversion. Use a supported unit and the format: 10 km to mi.") }
    }
    private func calculate() {
        do { session.calculatorResult = try store.calculate(.expression(session.calculatorInput)) }
        catch { session.calculatorResult = L("Invalid or unsupported expression") }
    }
}
