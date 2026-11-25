import Foundation
import Testing
import AICore
import AgentCore
@testable import MCPAdapters

@Suite struct MCPToolContractDigestTests {
    private func tool(name: String = "synthetic_tool", hint: Bool? = nil) -> MCPToolDescriptor {
        .init(originalName: "original", definition: .init(name: name, description: "Synthetic tool", parameters: ["type": .string("object"), "properties": .object([:]), "required": .array([.string("a"), .string("b")])]), untrustedReadOnlyHint: hint)
    }
    private func catalog(_ tools: [MCPToolDescriptor], serverID: UUID = UUID(), configurationRevision: UUID = UUID(), revision: String = "connection-one", rejected: [MCPRejectedTool] = []) -> MCPToolCatalog {
        .init(serverID: serverID, configurationRevision: configurationRevision, revision: revision, tools: tools, rejectedTools: rejected)
    }
    @Test func reconnectAndCatalogOrderDoNotChangeTheSelectedContract() throws {
        let first = catalog([tool(), tool(name: "other")]), names: Set<String> = ["synthetic_tool", "other"]
        let next = catalog(first.tools.reversed(), serverID: first.serverID, configurationRevision: first.configurationRevision, revision: "new-client-generation")
        #expect(try first.selectedContractDigest(names: names) == next.selectedContractDigest(names: names))
        let selected = try first.selectedContractDigest(names: ["synthetic_tool"])
        let extra = catalog([tool(name: "unselected"), tool()], serverID: first.serverID, configurationRevision: first.configurationRevision)
        #expect(try extra.selectedContractDigest(names: ["synthetic_tool"]) == selected)
    }
    @Test func exactDescriptionSchemaHintAndSourceChangesInvalidateReview() throws {
        let original = tool(), first = catalog([original]), expected = try first.selectedContractDigest(names: [original.id])
        var description = original.definition; description.description += " "
        var number = original.definition; number.parameters["maximum"] = .number(1)
        var array = original.definition; array.parameters["required"] = .array([.string("b"), .string("a")])
        let changed = [
            MCPToolDescriptor(originalName: "different", definition: original.definition, untrustedReadOnlyHint: nil),
            .init(originalName: original.originalName, definition: description, untrustedReadOnlyHint: nil),
            .init(originalName: original.originalName, definition: number, untrustedReadOnlyHint: nil),
            .init(originalName: original.originalName, definition: array, untrustedReadOnlyHint: nil), tool(hint: false), tool(hint: true)
        ]
        for value in changed {
            let next = catalog([value], serverID: first.serverID, configurationRevision: first.configurationRevision)
            #expect(try next.selectedContractDigest(names: [original.id]) != expected)
        }
        #expect(try catalog([original], serverID: UUID(), configurationRevision: first.configurationRevision).selectedContractDigest(names: [original.id]) != expected)
        #expect(try catalog([original], serverID: first.serverID, configurationRevision: UUID()).selectedContractDigest(names: [original.id]) != expected)
    }
    @Test func objectKeyOrderIsStableButUnicodeByteChangesAreNot() throws {
        let first = catalog([tool()]); var reordered = first.tools[0].definition
        reordered.parameters = [:]; reordered.parameters["required"] = .array([.string("a"), .string("b")]); reordered.parameters["properties"] = .object([:]); reordered.parameters["type"] = .string("object")
        let next = catalog([.init(originalName: "original", definition: reordered, untrustedReadOnlyHint: nil)], serverID: first.serverID, configurationRevision: first.configurationRevision)
        #expect(try first.selectedContractDigest(names: ["synthetic_tool"]) == next.selectedContractDigest(names: ["synthetic_tool"]))
        var nfc = reordered, nfd = reordered; nfc.description = "Caf\u{e9}"; nfd.description = "Cafe\u{301}"
        let a = catalog([.init(originalName: "original", definition: nfc, untrustedReadOnlyHint: nil)], serverID: first.serverID, configurationRevision: first.configurationRevision)
        let b = catalog([.init(originalName: "original", definition: nfd, untrustedReadOnlyHint: nil)], serverID: first.serverID, configurationRevision: first.configurationRevision)
        #expect(try a.selectedContractDigest(names: ["synthetic_tool"]) != b.selectedContractDigest(names: ["synthetic_tool"]))
    }
    @Test func missingDuplicateAndRejectedSelectionsFailWithoutPartialDigest() throws {
        let first = catalog([tool()])
        #expect(throws: MCPClientError.catalogChanged) { try first.selectedContractDigest(names: ["missing", "synthetic_tool"]) }
        #expect(throws: MCPClientError.catalogChanged) { try catalog([tool(), tool()]).selectedContractDigest(names: ["synthetic_tool"]) }
        #expect(throws: MCPClientError.catalogChanged) { try catalog([tool()], rejected: [.init(originalName: "original", reason: .unsupportedSchema)]).selectedContractDigest(names: ["synthetic_tool"]) }
    }
    @Test func nonFiniteAndUnboundedSchemasAreRejected() throws {
        var value = tool().definition; value.parameters["maximum"] = .number(.nan)
        #expect(throws: MCPClientError.unsupportedSchema) { try catalog([.init(originalName: "original", definition: value, untrustedReadOnlyHint: nil)]).selectedContractDigest(names: ["synthetic_tool"]) }
        var nested = JSONValue.null; for _ in 0..<34 { nested = .array([nested]) }; value.parameters = ["nested": nested]
        #expect(throws: MCPClientError.limitExceeded) { try catalog([.init(originalName: "original", definition: value, untrustedReadOnlyHint: nil)]).selectedContractDigest(names: ["synthetic_tool"]) }
    }
    @Test func acceptedSchemaBudgetsAreNotReducedByDigestRepresentationExpansion() throws {
        let schema: [String: JSONValue] = ["type": .string("object"), "examples": .array(Array(repeating: .number(0), count: 8_000))]
        try ToolJSONSchema.checkSchema(schema)
        #expect(try JSONEncoder().encode(schema).count < 65_536)
        let values: [MCPToolDescriptor] = (0..<4).map { .init(originalName: "original_\($0)", definition: .init(name: "synthetic_\($0)", description: "Synthetic large valid schema", parameters: schema), untrustedReadOnlyHint: nil) }
        let first = catalog(values), names = Set(values.map(\.id))
        #expect(try first.selectedContractDigest(names: names).count == 64)
        #expect(try first.selectedContractDigest(names: names) == catalog(values.reversed(), serverID: first.serverID, configurationRevision: first.configurationRevision, revision: "reconnected").selectedContractDigest(names: names))
    }
}
