import Foundation
import Testing
import MCPAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct MCPSettingsBudgetTests {
    @Test func editingStartupKeepsRequestBudgetAndRejectsInvalidValuesBeforeSaving() async throws {
        try await withWorkflowIntegrationFixture { fixture in
            var draft = MCPServerDraft()
            draft.name = "Synthetic local server"; draft.kind = .stdio
            draft.executable = "/usr/bin/true"; draft.directory = "/tmp"
            draft.startupTimeout = "17"; draft.requestTimeout = "1"
            #expect(await fixture.store.saveMCPServer(draft))
            let first = try #require(fixture.store.configuration.mcpServers.first)
            #expect(first.timeoutSeconds == 1 && first.stdioLaunch?.startupTimeoutSeconds == 17)
            var edited = MCPServerDraft(first); edited.startupTimeout = "19"
            #expect(await fixture.store.saveMCPServer(edited))
            let saved = try #require(fixture.store.configuration.mcpServers.first)
            #expect(saved.timeoutSeconds == 1 && saved.stdioLaunch?.startupTimeoutSeconds == 19)
            edited = MCPServerDraft(saved)
            edited.startupTimeout = "0"
            #expect(await fixture.store.saveMCPServer(edited) == false)
            #expect(fixture.store.configuration.mcpServers == [saved])
            edited.startupTimeout = "19"; edited.requestTimeout = "inf"
            #expect(await fixture.store.saveMCPServer(edited) == false)
            #expect(fixture.store.configuration.mcpServers == [saved])
            await fixture.assertNoExecution()
        }
    }
}
