import Foundation
import CryptoKit
import CommandCore

enum CalculatorInput: Sendable { case expression(String), conversion(String), query(String) }
struct PreparedCalculation: Sendable { let expression:String; let value:String }

enum CalculatorContribution {
    static func calculate(_ input:CalculatorInput) throws -> PreparedCalculation {
        let expression: String
        switch input { case .expression(let text), .conversion(let text), .query(let text): expression = text }
        guard expression.utf8.count <= 256 else { throw ContributionCatalogError.invalidInput }
        func arithmetic() throws -> String { String(format:"%.12g",try UtilityExpression.evaluate(expression)) }
        func conversion() throws -> String { let value = try UnitConversion.convert(expression); return String(format:"%.12g",value.value)+" "+value.targetUnit }
        let result: String
        switch input {
        case .expression: result = try arithmetic()
        case .conversion: result = try conversion()
        case .query: if let value = try? arithmetic() { result = value } else { result = try conversion() }
        }
        return .init(expression:expression,value:result)
    }
    static func revision(_ value:PreparedCalculation) -> String { SHA256.hash(data:Data((value.expression+"|"+value.value).utf8)).map { String(format:"%02x",$0) }.joined() }
    static func prepare(_ item:CommandItem) throws -> PreparedCalculation {
        guard item.kind == .utility, item.id == "utility.calculator.result", let text = item.contribution?.input else { throw ContributionCatalogError.invalidInput }
        let result = try calculate(.query(text))
        guard item.payload == "calculate."+result.value, item.title == result.value, item.objectRevision == revision(result) else { throw ContributionCatalogError.invalidInput }
        return result
    }
    static func manifest() throws -> ContributionManifest {
        let action = try HostActionCatalog.action(.copyText,title:"Copy calculated result")
        let providerRef = try CommandExecutionReference(toolID:"keydock.provider.calculator",toolVersion:1)
        return try ContributionManifest(reference:.init(toolID:BuiltinContributionID.calculator,toolVersion:1),provider:providerRef,
            descriptor:.init(id:BuiltinContributionID.calculator,version:1,title:"Calculator",providerID:providerRef.toolID,actions:[action]),commandPrefixes:["utility.calculator.result"],payloadPrefixes:["calculate."])
    }
    @MainActor static func definition() throws -> BuiltinContributionDefinition {
        let manifest = try manifest(), action = manifest.descriptor.defaultAction
        let provider = ContributionProviderRegistration(manifest:manifest,
            presentation:{(L("Calculator and unit conversion"),L("Evaluate arithmetic and convert units. Results are copied only when selected."))},dismissAfterSelection:true,
            catalogItems:{_,_ in []},querySource:{_,snapshot,_,_ in
                .init(provider:CalculatorQueryProvider(snapshot:snapshot),prepareSelection:{item,_ in try prepare(item)})
            },prepareItem:{_,item in try prepare(item)},read:{ input in guard let input = input as? CalculatorInput else { throw ContributionCatalogError.invalidInput }; return try calculate(input).value })
        let handler = ContributionHandlerRegistration(contract:.init(action:action),body:.immediate { store,resolved,payload,caller in
            guard let result = payload as? PreparedCalculation else { throw ContributionCatalogError.invalidInput }
            _ = try store.authorizeContribution(resolved,resource:"general|"+store.fingerprint(result.value),caller:caller)
            store.latestAutoCopyRunID = nil
            try store.clipboardWriter(result.value)
            return .completed
        })
        return .init(provider:provider,handlers:[handler])
    }
}

private struct CalculatorQueryProvider: CommandProviding {
    let id = "keydock.provider.calculator"
    let snapshot: ContributionCatalogSnapshot
    func commands(matching query:String) async throws -> [CommandItem] {
        try Task.checkCancellation()
        guard let result = try? CalculatorContribution.calculate(.query(query)) else { return [] }
        let binding = try snapshot.binding(for:BuiltinContributionID.calculator,input:query)
        return [.init(id:"utility.calculator.result",title:result.value,subtitle:query,keywords:[query],kind:.utility,payload:"calculate."+result.value,objectRevision:CalculatorContribution.revision(result),contribution:binding)]
    }
}

extension WorkbenchModel {
    func calculate(_ input:CalculatorInput) throws -> String {
        guard contributionSnapshot.isEnabled(BuiltinContributionID.calculator),
              let provider = contributions.providers.first(where:{$0.manifest.reference.toolID == BuiltinContributionID.calculator}),
              let read = provider.read, let result = try read(input) as? String else { throw ContributionCatalogError.unavailable }
        return result
    }
}
