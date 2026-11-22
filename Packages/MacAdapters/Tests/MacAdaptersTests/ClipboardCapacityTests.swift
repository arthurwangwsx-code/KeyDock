import Foundation
import Testing
import CSQLite
@testable import MacAdapters

@Suite(.serialized) struct ClipboardCapacityTests {
    @Test func rejectedEntryPreservesOldUnpinnedHistoryWhenPinsConsumeTheBudget() async throws {
        try await withDatabase { store, _ in
            try await store.insert(text: "PPPPPP", source: "synthetic")
            let pinned = try #require(await store.entries().first)
            try await store.setPinned(id: pinned.id, pinned: true)
            try await store.insert(text: "old", source: "synthetic")
            #expect(try await store.insert(text: "12345", source: "synthetic") == .rejected(.capacity))
            #expect(Set(try await store.entries().map(\.text)) == ["PPPPPP", "old"])
        }
    }

    @Test func fullPinnedBudgetsAllowDuplicatesButRejectNewEntries() async throws {
        for countLimited in [true, false] {
            var limits = ClipboardLimits(); limits.maxEntries = countLimited ? 1 : 3
            limits.maxItemBytes = 10; limits.maxTotalBytes = countLimited ? 10 : 6
            try await withDatabase(limits: limits) { store, _ in
                #expect(try await store.insert(text: "PPPPPP", source: "synthetic") == .stored)
                let row = try #require(await store.entries().first)
                try await store.setPinned(id: row.id, pinned: true)
                #expect(try await store.insert(text: "PPPPPP", source: "synthetic") == .refreshed)
                #expect(try await store.insert(text: "x", source: "synthetic") == .rejected(.capacity))
                let remaining = try await store.entries()
                #expect(remaining.count == 1 && remaining.first?.id == row.id && remaining.first?.pinned == true)
            }
        }
    }

    @Test func acceptedEntrySurvivesEvenWhenItsTimestampIsEarlier() async throws {
        try await withDatabase { store, _ in
            let now = Date()
            try await store.insert(text: "aaa", source: "synthetic", now: now.addingTimeInterval(1))
            try await store.insert(text: "bbb", source: "synthetic", now: now.addingTimeInterval(2))
            #expect(try await store.insert(text: "CCCCCC", source: "synthetic", now: now) == .stored)
            #expect(Set(try await store.entries().map(\.text)) == ["bbb", "CCCCCC"])
        }
    }

    @Test func emptyAndOversizedUTF8InputsHaveExplicitOutcomes() async throws {
        try await withDatabase { store, _ in
            let empty = try await store.insert(text: "", source: "synthetic")
            let oversized = try await store.insert(text: "😃😃😃", source: "synthetic")
            let remaining = try await store.entries()
            #expect(empty == .ignoredEmpty && oversized == .rejected(.itemTooLarge))
            #expect(remaining.isEmpty)
        }
    }

    @Test func invalidLimitsAreRejectedBeforeOpeningTheDatabase() throws {
        var base = ClipboardLimits()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-InvalidLimits-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<5 {
            base = ClipboardLimits()
            switch index {
            case 0: base.maxEntries = 0
            case 1: base.maxItemBytes = -1
            case 2: base.maxTotalBytes = 0
            case 3: base.retention = .infinity
            default: base.retention = 0
            }
            #expect(throws: ClipboardDatabaseError.invalidLimits) { try ClipboardStore(url: directory.appendingPathComponent("clips.sqlite"), limits: base) }
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test func databaseFailureCannotLeaveAnOverCapacityPartialInsert() async throws {
        try await withDatabase { store, url in
            try await store.insert(text: "older", source: "synthetic")
            try await store.insert(text: "newer", source: "synthetic")
            try execute("CREATE TRIGGER synthetic_prune_failure BEFORE DELETE ON clips BEGIN SELECT RAISE(ABORT,'synthetic'); END;", at: url)
            do {
                try await store.insert(text: "third", source: "synthetic")
                Issue.record("Synthetic database failure must be reported")
            } catch ClipboardDatabaseError.statement {}
            // 删除测试触发器后才能读取；生产查询会先执行正常清理。
            try execute("DROP TRIGGER synthetic_prune_failure;", at: url)
            let check = try ClipboardStore(url: url)
            #expect(Set(try await check.entries().map(\.text)) == ["older", "newer"])
        }
    }

    private func withDatabase(limits supplied: ClipboardLimits? = nil, _ body: (ClipboardStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Capacity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = ClipboardLimits(); limits.maxEntries = 3; limits.maxItemBytes = 10; limits.maxTotalBytes = 10
        if let supplied { limits = supplied }
        let url = directory.appendingPathComponent("clips.sqlite")
        let store = try ClipboardStore(url: url, limits: limits)
        try await body(store, url)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ClipboardDatabaseError.open }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ClipboardDatabaseError.statement }
    }
}
