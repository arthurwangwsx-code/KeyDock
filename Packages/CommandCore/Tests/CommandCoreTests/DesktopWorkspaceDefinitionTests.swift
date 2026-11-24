import Foundation
import Testing
@testable import CommandCore

struct DesktopWorkspaceDefinitionTests {
    private func entry(_ app: String = "Synthetic") throws -> DesktopWorkspaceEntry {
        try .init(applicationID: "app./Applications/" + app + ".app", layout: .leftHalf)
    }
    @Test func orderedArchivePreservesExactReferencesAndContainsOnlyDefinitionFields() throws {
        let path = "app./Applications/Cafe\u{301}.app"
        let first = try DesktopWorkspaceEntry(applicationID: path, layout: .rightHalf, display: .mainDisplay, missingApplication: .launchInBackground)
        let second = try entry("Other")
        let value = try SavedDesktopWorkspace(revision: 3, name: "  中文 👨‍💻  ", entries: [first,second])
        let archive = try DesktopWorkspaceArchive(workspaces: [value]), bytes = try archive.encoded()
        let decoded = try DesktopWorkspaceArchive.decode(bytes)
        #expect(decoded == archive && decoded.workspaces[0].name == "中文 👨‍💻")
        #expect(decoded.workspaces[0].entries.map(\.id) == [first.id,second.id])
        #expect(decoded.workspaces[0].entries[0].applicationID.utf8.elementsEqual(path.utf8))
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        let definitions = try #require(json["workspaces"] as? [[String:Any]]), rows = try #require(definitions[0]["entries"] as? [[String:Any]])
        #expect(Set(definitions[0].keys) == ["id","revision","name","entries"])
        #expect(Set(rows[0].keys) == ["id","applicationID","selector","layout","display","missingApplication"])
    }
    @Test(arguments: ["app.Relative.app","app.//Applications/Synthetic.app","app./Applications/../Synthetic.app","app./Applications/./Synthetic.app","app./Applications//Synthetic.app","app./Applications/Synthetic.app/","app./Applications/Synthetic.dmg","app./Applications/Synthetic\n.app","app./Applications/Synthetic\0.app"])
    func malformedReferencesAreRejectedWithoutFilesystemResolution(path: String) {
        #expect(throws: DesktopWorkspaceValidationError.invalidDefinition) { try DesktopWorkspaceEntry(applicationID: path) }
    }
    @Test func duplicateAndBudgetedDefinitionsAreRejected() throws {
        let first = try entry()
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: " ", entries: [first]) }
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: String(repeating: "中", count: 54), entries: [first]) }
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: "A\nB", entries: [first]) }
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(revision: 0, name: "Synthetic", entries: [first]) }
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: "Synthetic", entries: []) }
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: "Synthetic", entries: [first,first]) }
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: "Synthetic", entries: [first,entry()]) }
        let sameID = try DesktopWorkspaceEntry(id: first.id, applicationID: "app./Applications/Other.app")
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: "Synthetic", entries: [first,sameID]) }
        #expect(throws: (any Error).self) { try SavedDesktopWorkspace(name: "Synthetic", entries: (0..<9).map { try entry(String($0)) }) }
        #expect(throws: (any Error).self) { try DesktopWorkspaceEntry(applicationID: first.applicationID, layout: .restore) }
        #expect(throws: (any Error).self) { try DesktopWorkspaceEntry(applicationID: first.applicationID, layout: .nextDisplay) }
        let value = try SavedDesktopWorkspace(name: "Synthetic", entries: [first])
        #expect(throws: (any Error).self) { try DesktopWorkspaceArchive(workspaces: [value,value]) }
        #expect(throws: (any Error).self) { try DesktopWorkspaceArchive(workspaces: (0..<33).map { _ in try SavedDesktopWorkspace(name: "Same name is allowed", entries: [first]) }) }
        let rows = try (0..<8).map { try entry(String($0)+String(repeating: "x", count: 4_050)) }
        let large = try DesktopWorkspaceArchive(workspaces: (0..<32).map { _ in try SavedDesktopWorkspace(name: "Synthetic", entries: rows) })
        #expect(throws: (any Error).self) { try large.encoded() }
        #expect(throws: (any Error).self) { try DesktopWorkspaceArchive.decode(Data(repeating: 0, count: DesktopWorkspaceArchive.maximumBytes+1)) }
    }
    @Test(arguments: ["schema","selector","layout","display","missingApplication"])
    func decoderRejectsUnknownVersionsAndPolicies(field: String) throws {
        let bytes = try DesktopWorkspaceArchive(workspaces: [SavedDesktopWorkspace(name: "Synthetic", entries: [entry()])]).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        if field == "schema" { object["schemaVersion"] = 2 }
        else {
            var definitions = try #require(object["workspaces"] as? [[String:Any]]), rows = try #require(definitions[0]["entries"] as? [[String:Any]])
            rows[0][field] = "unsupported"; definitions[0]["entries"] = rows; object["workspaces"] = definitions
        }
        let modified = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try DesktopWorkspaceArchive.decode(modified) }
    }
}
