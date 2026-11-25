import Foundation
import CommandCore
import MacAdapters

@MainActor struct PreparedFileReveal {
    let result: FileSearchResult
    let service: FileSearchService
    let folders: [SearchFolder]
    let stillCurrent: @MainActor ()->Bool
}

enum FileSearchContribution {
    static func manifest() throws -> ContributionManifest {
        let action = try HostActionCatalog.action(.revealFile,title:"Reveal in Finder")
        let providerRef = try CommandExecutionReference(toolID:"keydock.provider.files",toolVersion:1)
        return try ContributionManifest(reference:.init(toolID:BuiltinContributionID.files,toolVersion:1),provider:providerRef,
            descriptor:.init(id:BuiltinContributionID.files,version:1,title:"File search",providerID:providerRef.toolID,actions:[action]),commandPrefixes:["file."],payloadPrefixes:["file."])
    }
    @MainActor static func definition() throws -> BuiltinContributionDefinition {
        let manifest = try manifest(), action = manifest.descriptor.defaultAction
        let provider = ContributionProviderRegistration(manifest:manifest,
            presentation:{(L("File search"),L("Search file names in chosen folders and reveal selected results in Finder. Folder permissions stay unchanged."))},dismissAfterSelection:false,
            catalogItems:{_,_ in []},querySource:{configuration,snapshot,service,options in
                guard let service, !configuration.searchFolders.isEmpty else { return nil }
                let folders = configuration.searchFolders
                let binding = try snapshot.binding(for:BuiltinContributionID.files)
                return .init(provider:FileSearchCommandProvider(service:service,folders:folders,binding:binding,limit:options.resultLimit,minimumQueryCharacters:options.minimumQueryCharacters),prepareSelection:{item,context in
                    guard let report = await service.currentReport(), let result = report.results.first(where:{"file."+$0.id == item.id}),
                          item.objectRevision == result.objectRevision, item.payload == item.id, item.kind == .utility,
                          item.contribution?.reference == binding.reference, item.contribution?.epoch == binding.epoch,
                          item.contribution?.input == report.requestID.uuidString else { throw ContributionCatalogError.invalidInput }
                    return PreparedFileReveal(result:result,service:service,folders:folders,stillCurrent:context.stillCurrent)
                })
            },prepareItem:nil,read:nil)
        let handler = ContributionHandlerRegistration(contract:.init(action:action),body:.asynchronous {store,resolved,payload,caller in
            guard let prepared = payload as? PreparedFileReveal else { throw ContributionCatalogError.invalidInput }
            return try await store.revealPreparedFile(prepared,resolved:resolved,caller:caller) ? .completed : .rejected
        })
        return .init(provider:provider,handlers:[handler])
    }
}
