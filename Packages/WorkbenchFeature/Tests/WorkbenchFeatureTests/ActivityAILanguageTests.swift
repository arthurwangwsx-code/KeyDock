import Foundation
import Testing
import AutomationCore
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct ActivityAILanguageTests {
    @Test(arguments: ["en", "zh-Hans"])
    func activitySummarySendsExplicitFrozenLanguageAcrossAUIChange(_ language: String) async throws {
        try await withStoreHTTPFixture(path: "system-prompt-echo") { f in
            #expect(f.store.setLanguage(language))
            await f.store.setActivityTracking(true)
            try await f.store.activityLedger.record(.init(commandID: "keydock.synthetic", category: .workflow, outcome: .succeeded, duration: 1))
            await f.store.refreshActivity(days: 7)
            #expect(f.store.activityReport?.totalCount == 1)
            f.store.summarizeActivity()
            let id = try #require(f.store.tasks.first?.id)
            #expect(f.store.setLanguage(language == "en" ? "zh-Hans" : "en"))
            try await f.drain(id)
            let task = try #require(f.store.tasks.first { $0.id == id })
            let expected = language == "en" ? "Write the final response in English (en)." : "Write the final response in Simplified Chinese (zh-Hans)."
            let other = language == "en" ? "Write the final response in Simplified Chinese (zh-Hans)." : "Write the final response in English (en)."
            #expect(task.status == .completed && task.output.contains(expected) && !task.output.contains(other))
            #expect(try await f.server.stats()["post_requests"] == 1)
        }
    }
}
