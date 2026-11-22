import Foundation
import Testing
import ExecutionCore
@testable import WorkbenchFeature

/// 真实 URLSession + loopback SSE + Store；不替代外部服务兼容性、质量或 macOS UI 验收。
@Suite(.serialized) @MainActor struct StoreAIIntegrationTests {
    @Test func draftToTaskUsesRealHTTPAndPersistsFrozenMetadataAndUsage() async throws {
        try await withStoreHTTPFixture(path: "stream") { fixture in
            let store = fixture.store
            let input = "Synthetic private input, absent from usage receipt " + UUID().uuidString
            let draft = store.createDraft(actionID: fixture.action.id, input: input)
            let id = try #require(store.runAI(action: fixture.action, draft: draft))
            // 请求创建后配置变化，不得重定向已开始的请求或改写归属。
            let alternate = fixture.server.baseURL.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")
            store.configuration.endpoint = alternate + "/error/401"
            store.configuration.model = "synthetic-reconfigured-model"
            draft.editInput("Synthetic replacement input")
            try await fixture.drain(id)
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .completed && task.finishedAt != nil)
            #expect(task.output == "你好，网络 🌍")
            #expect(task.draftID == draft.id && task.modelName == "synthetic-store-model")
            #expect(task.source == .manual && task.sourceApplication == nil)
            #expect(draft.latestRunID == id && draft.input == "Synthetic replacement input")
            #expect(!store.canReplaceResult(id))
            let receipt = try fixture.usage(id)
            #expect(receipt.runID == id && receipt.outcome == "succeeded")
            #expect(receipt.endpointHost == "127.0.0.1" && receipt.model == "synthetic-store-model")
            #expect(receipt.purpose == fixture.action.id.uuidString && receipt.costBasis == "unknown")
            #expect(receipt.observations.count == 1 && receipt.unknownAttempts.isEmpty && !receipt.hasUnknownUsage)
            let usage = try #require(receipt.observations.first)
            #expect(usage.inputTokens == 12 && usage.outputTokens == 5)
            #expect(usage.responseID == "synthetic-network-response" && usage.counting == "cumulative")
            let serialized = String(decoding: try fixture.usageData(id), as: UTF8.self)
            #expect(!serialized.contains(input) && !serialized.contains("你好，网络"))
            #expect(!serialized.contains("synthetic-private-response-body"))
            let permissions = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("usage/" + id.uuidString + ".json").path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
            let stats = try await fixture.server.stats()
            #expect(stats["authorization_seen"] == 0)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func cancellingStoreTaskClosesTheSocketAndRecordsUnknownUsage() async throws {
        try await withStoreHTTPFixture(path: "slow") { fixture in
            let store = fixture.store
            let draft = store.createDraft(actionID: fixture.action.id, input: "Synthetic cancel input")
            let id = try #require(store.runAI(action: fixture.action, draft: draft))
            try await storeEventually {
                !(store.tasks.first { $0.id == id }?.output.isEmpty ?? true)
            }
            let start = ContinuousClock.now
            store.cancelTask(id)
            try await fixture.drain(id)
            #expect(ContinuousClock.now - start < .seconds(3))
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .cancelled && task.finishedAt != nil)
            #expect(!store.cancelledTaskIDs.contains(id))
            let outputAtCancellation = task.output
            try await storeEventually(.seconds(3)) {
                let stats = try await fixture.server.stats()
                return stats["slow_closed"] == 1 && stats["slow_open"] == 0
            }
            #expect(store.tasks.first { $0.id == id }?.output == outputAtCancellation)
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "cancelled" && receipt.hasUnknownUsage)
            #expect(receipt.observations.isEmpty && receipt.costBasis == "unknown")
            #expect(draft.notice.isEmpty)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func commandProposalQueuesReviewWithoutSavingOrExecuting() async throws {
        try await withStoreHTTPFixture(path: "proposal") { fixture in
            let store = fixture.store
            let marker = fixture.directory.appendingPathComponent("synthetic-must-never-exist")
            let draft = store.createDraft(input: marker.path)
            var reviews: [SavedCommand] = []
            var navigationCount = 0
            store.onReviewCommand = { reviews.append($0) }
            store.onOpenWorkspace = { _ in navigationCount += 1 }
            store.generateCommandProposal(draft: draft)
            let id = try #require(store.proposalRequests[draft.id])
            try await fixture.drain(id)
            #expect(reviews.count == 1)
            let proposal = try #require(reviews.first)
            #expect(proposal.executable == "/usr/bin/touch" && proposal.arguments == [marker.path])
            #expect(proposal.workingDirectory.isEmpty)
            #expect(store.tasks.count == 1 && store.tasks.first?.status == .draftReady)
            #expect(draft.latestRunID == nil && navigationCount == 0)
            #expect(draft.notice.contains("Synthetic proposal only"))
            #expect(try fixture.usage(id).purpose == "command-proposal")
            try fixture.assertNoCommandEffects(marker: marker)
        }
    }

    @Test func editedDraftCannotReceiveHeldProposalOrItsNotice() async throws {
        try await withStoreHTTPFixture(path: "proposal-held") { fixture in
            let store = fixture.store
            let marker = fixture.directory.appendingPathComponent("synthetic-stale-proposal")
            let draft = store.createDraft(input: marker.path)
            var reviewCount = 0
            store.onReviewCommand = { _ in reviewCount += 1 }
            store.generateCommandProposal(draft: draft)
            let id = try #require(store.proposalRequests[draft.id])
            try await storeEventually { try await fixture.server.stats()["proposal_started"] == 1 }
            draft.editInput("Synthetic newer input")
            draft.notice = "Synthetic newer notice"
            try await fixture.server.releaseProposals()
            try await fixture.drain(id)
            #expect(reviewCount == 0 && draft.notice == "Synthetic newer notice")
            #expect(store.tasks.first { $0.id == id }?.status == .draftReady)
            #expect(store.tasks.first { $0.id == id }?.output.contains(marker.path) == true)
            try fixture.assertNoCommandEffects(marker: marker)
        }
    }

    @Test func newerRequestSuppressesHeldProposalEvenWhenDraftRevisionIsUnchanged() async throws {
        try await withStoreHTTPFixture(path: "proposal-held") { fixture in
            let store = fixture.store
            let marker = fixture.directory.appendingPathComponent("synthetic-repeated-proposal")
            let draft = store.createDraft(input: marker.path)
            let revision = draft.revision
            var reviews: [SavedCommand] = []
            store.onReviewCommand = { reviews.append($0) }
            store.generateCommandProposal(draft: draft)
            let first = try #require(store.proposalRequests[draft.id])
            try await storeEventually { try await fixture.server.stats()["proposal_started"] == 1 }
            store.generateCommandProposal(draft: draft)
            let second = try #require(store.proposalRequests[draft.id])
            #expect(first != second && draft.revision == revision)
            try await storeEventually { try await fixture.server.stats()["proposal_started"] == 2 }
            try await fixture.server.releaseProposals()
            try await fixture.drain(first); try await fixture.drain(second)
            #expect(reviews.count == 1 && reviews.first?.name == "Synthetic proposal 2")
            #expect(store.tasks.filter { $0.status == .draftReady }.count == 2)
            try fixture.assertNoCommandEffects(marker: marker)
        }
    }

    @Test func readOnlyAgentCompletesActualHostToolRoundTripAndKeepsAttemptUsageSeparate() async throws {
        try await withStoreHTTPFixture(path: "agent") { fixture in
            let store = fixture.store
            let draft = store.createDraft(input: "Synthetic request for the current time")
            var workspaceIDs: [UUID] = []
            store.onOpenWorkspace = { route in
                if case .tasks(let id) = route, let id { workspaceIDs.append(id) }
            }
            store.runReadOnlyAgent(draft: draft)
            let id = try #require(workspaceIDs.first)
            try await fixture.drain(id)
            #expect(workspaceIDs == [id])
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .completed && task.draftID == draft.id)
            #expect(task.output.contains("current_time"))
            #expect(task.output.contains("Synthetic read-only tool round-trip complete"))
            let stats = try await fixture.server.stats()
            #expect(stats["agent_requests"] == 2 && stats["agent_tool_messages"] == 1)
            #expect(stats["authorization_seen"] == 0)
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "succeeded" && receipt.purpose == "readonly-agent")
            #expect(receipt.observations.count == 2 && !receipt.hasUnknownUsage)
            #expect(Set(receipt.observations.map(\.attemptID)).count == 2)
            #expect(Set(receipt.observations.compactMap(\.responseID)) == ["synthetic-agent-1", "synthetic-agent-2"])
            let first = try #require(receipt.observations.first { $0.responseID == "synthetic-agent-1" })
            let second = try #require(receipt.observations.first { $0.responseID == "synthetic-agent-2" })
            #expect(first.inputTokens == 10 && first.outputTokens == 4)
            #expect(second.inputTokens == 20 && second.outputTokens == 6)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test func ordinaryAIActionDoesNotAdvertiseOrExecuteUnexpectedTools() async throws {
        try await withStoreHTTPFixture(path: "unexpected-tool") { fixture in
            let store = fixture.store
            let draft = store.createDraft(actionID: fixture.action.id, input: "Synthetic text action")
            var reviewCount = 0
            store.onReviewCommand = { _ in reviewCount += 1 }
            let id = try #require(store.runAI(action: fixture.action, draft: draft))
            try await fixture.drain(id)
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .failed && !task.notice.isEmpty && task.output.isEmpty)
            #expect(!draft.notice.isEmpty && reviewCount == 0)
            let stats = try await fixture.server.stats()
            #expect(stats["ordinary_tools_advertised"] == 0 && stats["agent_requests"] == 0)
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "failed" && receipt.hasUnknownUsage)
            try fixture.assertNoCommandEffects()
        }
    }

    @Test(arguments: [401, 429]) func failedHTTPProducesSanitizedTaskAndUnknownUsage(status: Int) async throws {
        try await withStoreHTTPFixture(path: "error/\(status)") { fixture in
            let store = fixture.store
            let input = "Synthetic confidential input " + UUID().uuidString
            let draft = store.createDraft(actionID: fixture.action.id, input: input)
            let id = try #require(store.runAI(action: fixture.action, draft: draft))
            try await fixture.drain(id)
            let task = try #require(store.tasks.first { $0.id == id })
            #expect(task.status == .failed && task.output.isEmpty && !task.notice.isEmpty)
            #expect(!task.notice.contains("synthetic-private-response-body"))
            #expect(!draft.notice.contains("synthetic-private-response-body"))
            let receipt = try fixture.usage(id)
            #expect(receipt.outcome == "failed" && receipt.hasUnknownUsage && receipt.observations.isEmpty)
            let serialized = String(decoding: try fixture.usageData(id), as: UTF8.self)
            #expect(!serialized.contains(input) && !serialized.contains("synthetic-private-response-body"))
            try fixture.assertNoCommandEffects()
        }
    }
}
