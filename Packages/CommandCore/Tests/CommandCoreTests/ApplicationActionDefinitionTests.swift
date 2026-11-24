import Foundation
import Testing
import CommandCore

struct ApplicationActionDefinitionTests {
    @Test func archiveRoundTripKeepsTypedBehaviorWithoutAnyGrantOrPID() throws {
        let action = try SavedApplicationAction(name: "  Synthetic editor  ", applicationID: "app./Applications/Synthetic Editor.app", behavior: .toggleVisibility)
        let data = try ApplicationActionArchive(actions: [action]).encoded()
        let restored = try ApplicationActionArchive.decode(data)
        #expect(restored.actions == [action] && action.name == "Synthetic editor")
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("effects") && !json.contains("grant") && !json.contains("pid"))
        #expect(ApplicationBehavior.launchOrActivate.mayLaunch && ApplicationBehavior.toggleVisibility.mayLaunch)
        #expect(!ApplicationBehavior.requestQuit.mayLaunch && !ApplicationBehavior.hide.mayLaunch)
    }
    @Test func unsupportedVersionDuplicateIDsAndInvalidReferencesAreRejected() throws {
        let action = try SavedApplicationAction(name: "Synthetic", applicationID: "app./Applications/Synthetic.app", behavior: .requestQuit)
        #expect(throws: (any Error).self) { try ApplicationActionArchive(actions: [action, action]) }
        #expect(throws: (any Error).self) { try SavedApplicationAction(name: "Synthetic", applicationID: "app.relative.app", behavior: .show) }
        #expect(throws: (any Error).self) { try SavedApplicationAction(name: "Synthetic", applicationID: "app./tmp/not-an-app.txt", behavior: .show) }
        #expect(throws: (any Error).self) { try SavedApplicationAction(name: "\0", applicationID: action.applicationID, behavior: .show) }
        let data = try ApplicationActionArchive(actions: [action]).encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(throws: (any Error).self) { try ApplicationActionArchive.decode(Data(json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2").utf8)) }
        #expect(throws: (any Error).self) { try ApplicationActionArchive.decode(Data(json.replacingOccurrences(of: "requestQuit", with: "forceTerminate").utf8)) }
    }
    @Test func actionAndByteBudgetsRejectWithoutTruncation() throws {
        let actions = try (0...ApplicationActionArchive.maximumActions).map { try SavedApplicationAction(name: "Synthetic \($0)", applicationID: "app./Applications/Synthetic.app", behavior: .show) }
        #expect(throws: (any Error).self) { try ApplicationActionArchive(actions: actions) }
        #expect(throws: (any Error).self) { try ApplicationActionArchive.decode(Data(repeating: 32, count: ApplicationActionArchive.maximumBytes + 1)) }
    }
}
