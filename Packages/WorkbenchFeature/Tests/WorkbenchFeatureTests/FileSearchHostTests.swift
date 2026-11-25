import Foundation
import Testing
@testable import WorkbenchFeature

@Suite(.serialized,.timeLimit(.minutes(1))) @MainActor struct FileSearchHostTests {
    @Test func emptyFoldersAndMissingProviderCannotLeaveTheProductionSessionBusy() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let session = FileSearchSession(); session.query = "synthetic"
            fixture.store.searchFiles(session)
            #expect(!session.busy && session.report == nil)
            session.search(plan:.init(epoch:fixture.store.contributionEpoch,sources:[:]),stillEnabled:{true})
            try await fixture.eventually { !session.busy }
            #expect(session.report == nil)
        }
    }

    @Test func launcherAndToolsRevealOnlyTheFreshOwnedResultAndRejectOldQueries() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, folder = fixture.directory.appendingPathComponent("selected",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let file = folder.appendingPathComponent("synthetic-reveal.txt")
            try Data("owned body".utf8).write(to:file); store.addSearchFolder(folder)
            var reveals: [[URL]] = []; store.fileRevealer = { reveals.append($0) }
            let launcher = LauncherSession(store:store); launcher.setVisible(true); launcher.query = "synthetic-reveal"
            try await fixture.eventually { launcher.resultBatch?.isComplete == true }
            let item = try #require(launcher.results.first(where:{$0.id.hasPrefix("file.")}))
            launcher.selectedID = item.id; launcher.execute()
            try await fixture.eventually { store.contributionActionTasks.isEmpty }
            #expect(reveals.count == 1)
            #expect(reveals.first?.map { $0.standardizedFileURL.path } == [file.resolvingSymlinksInPath().standardizedFileURL.path])
            let session = FileSearchSession(); session.query = "synthetic-reveal"
            store.searchFiles(session); try await fixture.eventually { !session.busy && session.report != nil }
            let result = try #require(session.report?.results.first), plan = try #require(session.selectionPlan)
            let old = try #require(session.resultItems["file."+result.id])
            store.revealFileResult(result,in:session)
            try await fixture.eventually { store.contributionActionTasks.isEmpty }
            #expect(reveals.count == 2)
            #expect(reveals.last?.map { $0.standardizedFileURL.path } == [file.resolvingSymlinksInPath().standardizedFileURL.path])
            let source = try #require(plan.sources[BuiltinContributionID.files])
            _ = try await source.provider.commands(matching:session.query)
            let handled = store.dispatchContributionSelection(old,plan:plan,stillCurrent:{true})
            #expect(handled)
            try await fixture.eventually { store.contributionActionTasks.isEmpty }
            #expect(reveals.count == 2)
            store.searchFiles(session); try await fixture.eventually { !session.busy && session.report != nil }
            store.revealFileResult(result,in:session)
            try await fixture.eventually { store.contributionActionTasks.isEmpty }
            #expect(reveals.count == 2)
            #expect(store.setContributionEnabled(false,id:BuiltinContributionID.files))
            #expect(store.setContributionEnabled(true,id:BuiltinContributionID.files))
            store.revealFileResult(result,in:session)
            try await fixture.eventually { store.contributionActionTasks.isEmpty }
            #expect(reveals.count == 2)
        }
    }

    @Test func revealRechecksEnablementAndScopeAfterRealAsynchronousValidation() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            let store = fixture.store, folder = fixture.directory.appendingPathComponent("selected",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data("owned".utf8).write(to:folder.appendingPathComponent("synthetic-late.txt")); store.addSearchFolder(folder)
            var reveals = 0; store.fileRevealer = { _ in reveals += 1 }
            let session = FileSearchSession(); session.query = "synthetic-late"
            store.searchFiles(session); try await fixture.eventually { !session.busy && session.report != nil }
            let plan = try #require(session.selectionPlan), item = try #require(session.resultItems.values.first)
            let source = try #require(plan.sources[BuiltinContributionID.files])
            let resolved = try store.resolveContribution(try #require(item.contribution),id:item.id,title:item.title)
            let prepared = try await source.prepareSelection(item,.init(stillCurrent:{
                #expect(store.setContributionEnabled(false,id:BuiltinContributionID.files)); return true
            }))
            let outcome = try await store.contributions.invokeAsync(resolved,payload:prepared,store:store,caller:.user)
            #expect(!outcome.accepted && reveals == 0)
            #expect(store.setContributionEnabled(true,id:BuiltinContributionID.files))
            store.searchFiles(session); try await fixture.eventually { !session.busy && session.report != nil }
            let nextPlan = try #require(session.selectionPlan), next = try #require(session.resultItems.values.first)
            let nextSource = try #require(nextPlan.sources[BuiltinContributionID.files])
            let nextResolved = try store.resolveContribution(try #require(next.contribution),id:next.id,title:next.title)
            let nextPrepared = try await nextSource.prepareSelection(next,.init(stillCurrent:{ store.configuration.searchFolders = []; return true }))
            let nextOutcome = try await store.contributions.invokeAsync(nextResolved,payload:nextPrepared,store:store,caller:.user)
            #expect(!nextOutcome.accepted && reveals == 0)
        }
    }

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
