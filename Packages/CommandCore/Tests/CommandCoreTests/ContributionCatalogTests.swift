import Foundation
import Testing
@testable import CommandCore

struct ContributionCatalogTests {
    @Test func overlappingProviderNamespacesCannotMakeOwnershipDependOnRegistrationOrder() throws {
        let original = try manifest(), action = original.descriptor.defaultAction
        func named(_ id:String,prefix:String) throws -> ContributionManifest {
            try .init(reference:.init(toolID:id,toolVersion:1),provider:original.provider,
                      descriptor:.init(id:id,version:1,title:"Synthetic namespace",providerID:original.provider.toolID,actions:[action]),commandPrefixes:[prefix])
        }
        let a = try named("synthetic.contribution.a",prefix:"synthetic."), b = try named("synthetic.contribution.b",prefix:"synthetic.child.")
        for manifests in [[a,b],[b,a]] {
            #expect(throws:ContributionCatalogError.invalidManifest) { try CompiledContributionCatalog(manifests:manifests,providers:[original.provider],handlers:[.init(action:action)]) }
        }
    }
    private func action(effects:Set<CommandEffect> = [.writeClipboard], input:CommandValueType = .text, toolVersion:Int = 1) throws -> ActionDescriptor {
        try .init(id:"synthetic.action.copy",version:1,title:"Copy",inputType:input,effects:effects,execution:.init(toolID:"synthetic.tool.copy",toolVersion:toolVersion))
    }
    private func manifest(action:ActionDescriptor? = nil, providerVersion:Int = 1) throws -> ContributionManifest {
        let value = try action ?? self.action()
        return try .init(reference:.init(toolID:"synthetic.contribution.math",toolVersion:1),provider:.init(toolID:"synthetic.provider.math",toolVersion:providerVersion),
            descriptor:.init(id:"synthetic.contribution.math",version:1,title:"Math",providerID:"synthetic.provider.math",actions:[value]))
    }
    private func catalog() throws -> CompiledContributionCatalog {
        let manifest = try manifest()
        return try .init(manifests:[manifest],providers:[manifest.provider],handlers:[.init(action:manifest.descriptor.defaultAction)])
    }
    @Test func resolutionKeepsTheRegisteredContractAndExactVersions() throws {
        let catalog = try catalog(), snapshot = catalog.snapshot(disabled:[],epoch:UUID())
        let binding = try snapshot.binding(for:"synthetic.contribution.math",input:"2+3")
        let resolved = try snapshot.resolve(binding,instanceID:"synthetic.command.result",title:"5")
        #expect(resolved.action == catalog.manifests[0].descriptor.defaultAction)
        #expect(resolved.descriptor.id == "synthetic.command.result" && resolved.descriptor.providerID == "synthetic.provider.math")
        #expect(resolved.descriptor.defaultAction.execution.toolVersion == 1 && resolved.descriptor.defaultAction.effects == [.writeClipboard])
    }
    @Test func duplicateAndMissingImplementationsAreRejected() throws {
        let value = try manifest(), contract = ContributionHandlerContract(action:value.descriptor.defaultAction)
        #expect(throws:ContributionCatalogError.duplicateContribution) { try CompiledContributionCatalog(manifests:[value,value],providers:[value.provider],handlers:[contract]) }
        #expect(throws:ContributionCatalogError.duplicateProvider) { try CompiledContributionCatalog(manifests:[value],providers:[value.provider,value.provider],handlers:[contract]) }
        #expect(throws:ContributionCatalogError.duplicateHandler) { try CompiledContributionCatalog(manifests:[value],providers:[value.provider],handlers:[contract,contract]) }
        #expect(throws:ContributionCatalogError.providerUnavailable) { try CompiledContributionCatalog(manifests:[value],providers:[],handlers:[contract]) }
        #expect(throws:ContributionCatalogError.handlerUnavailable) { try CompiledContributionCatalog(manifests:[value],providers:[value.provider],handlers:[]) }
    }
    @Test func unavailableVersionsNeverFallBackToTheInstalledVersion() throws {
        let value = try manifest(providerVersion:2), contract = ContributionHandlerContract(action:value.descriptor.defaultAction)
        #expect(throws:ContributionCatalogError.providerUnavailable) { try CompiledContributionCatalog(manifests:[value],providers:[.init(toolID:"synthetic.provider.math",toolVersion:1)],handlers:[contract]) }
        let wrongTool = try manifest(action:action(toolVersion:2))
        #expect(throws:ContributionCatalogError.handlerUnavailable) { try CompiledContributionCatalog(manifests:[wrongTool],providers:[wrongTool.provider],handlers:[contract]) }
        let snapshot = try catalog().snapshot(disabled:[],epoch:UUID())
        let wrongReference = CommandContributionReference(contribution:try .init(toolID:"synthetic.contribution.math",toolVersion:2),action:try .init(toolID:"synthetic.action.copy",toolVersion:1))
        let binding = try CommandContributionBinding(reference:wrongReference,epoch:snapshot.epoch)
        #expect(throws:ContributionCatalogError.versionMismatch) { try snapshot.resolve(binding,instanceID:"synthetic.command.result",title:"Result") }
    }
    @Test func changingEffectsOrInputCannotBorrowARegisteredHandler() throws {
        let contract = ContributionHandlerContract(action:try action())
        for changed in [try action(effects:[.executeProcess]), try action(input:.structuredData)] {
            let value = try manifest(action:changed)
            #expect(throws:ContributionCatalogError.handlerContractMismatch) { try CompiledContributionCatalog(manifests:[value],providers:[value.provider],handlers:[contract]) }
        }
    }
    @Test func disabledAndReenabledSnapshotsRejectOldBindingsAndKeepOldResolutionFrozen() throws {
        let catalog = try catalog(), original = catalog.snapshot(disabled:[],epoch:UUID())
        let binding = try original.binding(for:"synthetic.contribution.math")
        let frozen = try original.resolve(binding,instanceID:"synthetic.command.result",title:"Result")
        let disabled = catalog.snapshot(disabled:["synthetic.contribution.math"],epoch:UUID())
        #expect(throws:ContributionCatalogError.unavailable) { try disabled.binding(for:"synthetic.contribution.math") }
        #expect(throws:ContributionCatalogError.staleSnapshot) { try disabled.resolve(binding,instanceID:"synthetic.command.result",title:"Result") }
        let enabled = catalog.snapshot(disabled:[],epoch:UUID())
        #expect(throws:ContributionCatalogError.staleSnapshot) { try enabled.resolve(binding,instanceID:"synthetic.command.result",title:"Result") }
        #expect(frozen.epoch == original.epoch && frozen.action.effects == [.writeClipboard])
    }
    @Test func malformedMetadataAndOversizedBindingAreRejectedBeforeUse() throws {
        let value = try manifest()
        #expect(throws:ContributionCatalogError.invalidManifest) { try ContributionManifest(reference:.init(toolID:"synthetic.contribution.other",toolVersion:1),provider:value.provider,descriptor:value.descriptor) }
        let snapshot = try catalog().snapshot(disabled:[],epoch:UUID())
        #expect(throws:ContributionCatalogError.invalidInput) { try snapshot.binding(for:"synthetic.contribution.math",input:String(repeating:"x",count:131_073)) }
        let legacy = Data("{\"id\":\"synthetic.legacy\",\"title\":\"Legacy\",\"subtitle\":\"\",\"keywords\":[],\"kind\":\"utility\",\"payload\":\"\"}".utf8)
        #expect(try JSONDecoder().decode(CommandItem.self,from:legacy).contribution == nil)
    }
}
