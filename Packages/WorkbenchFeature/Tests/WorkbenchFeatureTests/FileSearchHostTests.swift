import Foundation
import Testing
@testable import WorkbenchFeature

@Suite(.serialized,.timeLimit(.minutes(1))) @MainActor struct FileSearchHostTests {
    @Test func chosenFolderBookmarkFeedsProductionLauncherAndRemovalInvalidatesResults() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let folder = fixture.directory.appendingPathComponent("selected",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data("unindexed body".utf8).write(to:folder.appendingPathComponent("synthetic-search-result.txt"))
            let store = fixture.store
            store.addSearchFolder(folder)
            #expect(store.configuration.searchFolders.count == 1)
            let launcher = LauncherSession(store:store)
            launcher.query = "synthetic-search-result"
            try await fixture.eventually { launcher.resultBatch?.isComplete == true }
            #expect(launcher.results.contains{$0.id.hasPrefix("file.") && $0.title == "synthetic-search-result.txt"})
            var next = store.configuration; next.searchFolders = []
            #expect(store.commitSettingsConfiguration(next))
            launcher.search()
            try await fixture.eventually { launcher.resultBatch?.isComplete == true }
            #expect(!launcher.results.contains{$0.id.hasPrefix("file.")})
        }
    }
}
