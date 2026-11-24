import SwiftUI
import MacAdapters
import UniformTypeIdentifiers

struct FileSearchPanel: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var search: FileSearchSession
    @State private var chooseFolder = false
    var body: some View {
        Section(L("File search")) {
            Text(L("Search file names only in chosen folders. Hidden files, packages and symbolic links are skipped. Results open their location in Finder.")).font(.caption).foregroundStyle(.secondary)
            ForEach(store.configuration.searchFolders) { folder in
                HStack { Text(folder.name); Spacer(); Button(L("Remove"),role:.destructive) { search.cancel(); store.removeSearchFolder(folder.id) } }
            }
            Button(L("Add search folder")) { chooseFolder = true }.disabled(store.configuration.searchFolders.count >= 8)
                .fileImporter(isPresented:$chooseFolder,allowedContentTypes:[.folder]) { result in if case .success(let url) = result { search.cancel(); store.addSearchFolder(url) } }
            HStack {
                TextField(L("File name"),text:$search.query).onSubmit(run)
                Button(L("Search"),action:run).disabled(store.configuration.searchFolders.isEmpty || search.query.isEmpty)
                if search.busy { ProgressView().controlSize(.small); Button(L("Cancel")) { search.cancel() } }
            }
            if !search.notice.isEmpty { Text(search.notice).foregroundStyle(.secondary) }
            if let report = search.report {
                Text(String(format:L("Scanned %d entries · %d results"),report.scannedItems,report.results.count)).font(.caption).foregroundStyle(.secondary)
                ForEach(report.results) { result in
                    HStack { Text(result.title).lineLimit(1); Spacer(); Button(L("Reveal in Finder")) { Task { if let service = search.service { await store.revealFile(result,service:service,stillCurrent:{search.report?.requestID == report.requestID}) } } } }
                }
            }
        }
    }
    private func run() { search.search(folders:store.configuration.searchFolders) }
}
