import AppKit
import Foundation
import CommandCore
import MacAdapters

public struct SearchFolder: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let bookmark: Data
}
/// 显式目录授权的临时lease；不替换失效bookmark，也不扩大到Home或父目录。
final class SearchFolderAccess: @unchecked Sendable {
    let urls: [URL]
    private let scoped: [URL]
    init(_ folders: [SearchFolder]) throws {
        guard folders.count <= 8 else { throw FileSearchError.invalidRoots }
        var values: [URL] = [], active: [URL] = []
        do {
            for folder in folders {
                guard folder.bookmark.count <= 65_536 else { throw FileSearchError.invalidRoots }
                var stale = false
                let url = try URL(resolvingBookmarkData:folder.bookmark,options:[.withSecurityScope,.withoutUI],bookmarkDataIsStale:&stale)
                guard !stale, url.isFileURL else { throw FileSearchError.scopeChanged }
                if url.startAccessingSecurityScopedResource() { active.append(url) }
                values.append(url)
            }
        } catch { for url in active { url.stopAccessingSecurityScopedResource() }; throw error }
        urls = values; scoped = active
    }
    deinit { for url in scoped { url.stopAccessingSecurityScopedResource() } }
}

struct FileSearchCommandProvider: CommandProviding {
    let id = "keydock.files"
    let service: FileSearchService
    let folders: [SearchFolder]
    func commands(matching query:String) async throws -> [CommandItem] {
        guard query.trimmingCharacters(in:.whitespacesAndNewlines).count >= 2, !folders.isEmpty else { return [] }
        let folders = folders
        let access = try await Task.detached { try SearchFolderAccess(folders) }.value
        let report = try await service.search(query:query,roots:access.urls,limit:30)
        withExtendedLifetime(access) {}
        return report.results.map { CommandItem(id:"file."+$0.id,title:$0.title,subtitle:L("Reveal in Finder"),keywords:[query],kind:.utility,payload:"file."+$0.id,objectRevision:$0.objectRevision) }
    }
}

@MainActor public final class FileSearchSession: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { cancel(); notice = "" } } }
    @Published var report: FileSearchReport?
    @Published var busy = false
    @Published var notice = ""
    let service = try? FileSearchService()
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    func search(folders:[SearchFolder]) {
        operation?.cancel(); generation = UUID(); let token = generation
        report = nil; notice = ""; busy = true; let submittedQuery = query
        operation = Task { [weak self] in
            guard let self, let service else { return }
            defer { if generation == token { busy = false } }
            do {
                let access = try await Task.detached { try SearchFolderAccess(folders) }.value
                let value = try await service.search(query:submittedQuery,roots:access.urls)
                withExtendedLifetime(access) {}
                guard !Task.isCancelled, generation == token else { return }; report = value
                if value.isPartial { notice = L("Partial results: a scope or search budget limited this search.") }
            } catch { if !Task.isCancelled, generation == token { notice = L("Search scope is unavailable or changed. Choose the folder again.") } }
        }
    }
    func cancel() { generation = UUID(); operation?.cancel(); operation = nil; report = nil; busy = false }
    deinit { operation?.cancel() }
}

extension WorkbenchModel {
    func addSearchFolder(_ url:URL) {
        do {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let properties = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true, configuration.searchFolders.count < 8 else { throw FileSearchError.invalidRoots }
            let data = try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            guard data.count <= 65_536 else { throw FileSearchError.invalidRoots }
            var next = configuration; next.searchFolders.append(.init(id:UUID(),name:String(url.lastPathComponent.prefix(200)),bookmark:data))
            _ = commitSettingsConfiguration(next)
        } catch { workspaceNoticeMessage = noticeKey("Folder could not be added. Choose a readable directory.") }
    }
    func removeSearchFolder(_ id:UUID) { var next = configuration; next.searchFolders.removeAll{$0.id == id}; _ = commitSettingsConfiguration(next) }
    func revealFile(_ result:FileSearchResult,service:FileSearchService,stillCurrent:@escaping @MainActor ()->Bool) async {
        do {
            let folders = configuration.searchFolders
            let access = try await Task.detached { try SearchFolderAccess(folders) }.value
            let url = try await service.validate(result,allowedRoots:access.urls)
            guard !isShuttingDown, stillCurrent(), configuration.searchFolders == folders else { return }
            try authorizeHostAction(id:"files.reveal",operation:.revealFile,resource:result.objectRevision)
            NSWorkspace.shared.activateFileViewerSelecting([url]); withExtendedLifetime(access) {}
        } catch { if !isShuttingDown, stillCurrent() { workspaceNoticeMessage = noticeKey("The file or search scope changed. Search again before revealing it.") } }
    }
}
