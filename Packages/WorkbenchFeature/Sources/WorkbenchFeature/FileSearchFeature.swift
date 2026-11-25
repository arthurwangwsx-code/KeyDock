import AppKit
import Foundation
import CommandCore
import MacAdapters
import ExecutionCore

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
    let id = "keydock.provider.files"
    let service: FileSearchService
    let folders: [SearchFolder]
    let binding: CommandContributionBinding
    let limit: Int
    let minimumQueryCharacters: Int
    func commands(matching query:String) async throws -> [CommandItem] {
        guard query.trimmingCharacters(in:.whitespacesAndNewlines).count >= minimumQueryCharacters, !folders.isEmpty else { return [] }
        let folders = folders
        let access = try await Task.detached { try SearchFolderAccess(folders) }.value
        let report = try await service.search(query:query,roots:access.urls,limit:limit)
        withExtendedLifetime(access) {}
        let issuedBinding = try CommandContributionBinding(reference:binding.reference,epoch:binding.epoch,input:report.requestID.uuidString)
        return report.results.map { CommandItem(id:"file."+$0.id,title:$0.title,subtitle:L("Reveal in Finder"),keywords:[query],kind:.utility,payload:"file."+$0.id,objectRevision:$0.objectRevision,contribution:issuedBinding) }
    }
}

@MainActor public final class FileSearchSession: ObservableObject {
    @Published var query = "" { didSet { if !query.utf8.elementsEqual(oldValue.utf8) { cancel(); notice = "" } } }
    @Published var report: FileSearchReport?
    @Published var busy = false
    @Published var notice = ""
    let service = try? FileSearchService()
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    private(set) var selectionPlan: ContributionQueryPlan?
    private(set) var resultItems: [String:CommandItem] = [:]
    func search(plan:ContributionQueryPlan,stillEnabled:@escaping @MainActor ()->Bool) {
        operation?.cancel(); generation = UUID(); let token = generation
        report = nil; notice = ""; busy = true; let submittedQuery = query
        selectionPlan = plan; resultItems = [:]
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { busy = false } }
            guard let service, let source = plan.sources[BuiltinContributionID.files] else { return }
            do {
                let items = try await source.provider.commands(matching:submittedQuery)
                guard let value = await service.currentReport(), !Task.isCancelled, generation == token, stillEnabled() else { return }
                resultItems = Dictionary(items.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first }); report = value
                if value.isPartial { notice = L("Partial results: a scope or search budget limited this search.") }
            } catch { if !Task.isCancelled, generation == token { notice = L("Search scope is unavailable or changed. Choose the folder again.") } }
        }
    }
    func cancel() { generation = UUID(); operation?.cancel(); operation = nil; report = nil; selectionPlan = nil; resultItems = [:]; busy = false }
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
    func searchFiles(_ session:FileSearchSession) {
        do {
            let configuration = configuration, snapshot = contributionSnapshot, folders = configuration.searchFolders
            guard snapshot.isEnabled(BuiltinContributionID.files) else { session.cancel(); contributionUnavailable(); return }
            guard !folders.isEmpty, !session.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { session.cancel(); return }
            let plan = try contributions.queryPlan(configuration:configuration,snapshot:snapshot,files:session.service,options:.init(resultLimit:50,minimumQueryCharacters:1))
            session.search(plan:plan,stillEnabled:{ [weak self] in self?.contributionEpoch == snapshot.epoch && self?.configuration.searchFolders == folders })
        } catch { session.cancel(); contributionUnavailable() }
    }
    func revealFileResult(_ result:FileSearchResult,in session:FileSearchSession) {
        guard let report = session.report, report.results.contains(result), let plan = session.selectionPlan,
              let item = session.resultItems["file."+result.id] else { contributionUnavailable(); return }
        _ = dispatchContributionSelection(item,plan:plan,stillCurrent:{ [weak session] in session?.report?.requestID == report.requestID })
    }
    func revealPreparedFile(_ prepared:PreparedFileReveal,resolved:ResolvedContributionAction,caller:ExecutionCaller) async throws -> Bool {
        let access = try await Task.detached { try SearchFolderAccess(prepared.folders) }.value
        let url = try await prepared.service.validate(prepared.result,allowedRoots:access.urls)
        guard !Task.isCancelled, !isShuttingDown, prepared.stillCurrent(), contributionEpoch == resolved.epoch,
              contributionSnapshot.isEnabled(resolved.manifest.reference.toolID), configuration.searchFolders == prepared.folders else { return false }
        _ = try authorizeContribution(resolved,resource:prepared.result.objectRevision,caller:caller)
        fileRevealer([url]); withExtendedLifetime(access) {}
        return true
    }
}
