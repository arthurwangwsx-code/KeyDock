import Foundation
import CommandCore

// 固定合成数据；不记录真实查询、标题、剪贴板或用户文件。
struct Timing: Encodable {
    let ordinal: Int
    let variant: String
    let milliseconds: Double
    let resultCount: Int
    let queryID: UUID?
    let generation: UInt64?
}
struct Distribution: Encodable {
    let scope: String
    let samples: [Timing]
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
    let targetMilliseconds = 50.0
    let pass: Bool
    init(scope: String, samples: [Timing]) throws {
        guard samples.count == 100, samples.allSatisfy({ $0.milliseconds.isFinite && $0.milliseconds >= 0 }) else { throw CocoaError(.coderReadCorrupt) }
        self.scope = scope; self.samples = samples
        let sorted = samples.map(\.milliseconds).sorted()
        p50Milliseconds = sorted[49]; p95Milliseconds = sorted[94]; maxMilliseconds = sorted[99]
        pass = p95Milliseconds <= 50
    }
}
struct Report: Encodable {
    let schemaVersion = 3
    let fixture = "keydock-synthetic-catalog-v1"
    let itemCount = 2_000
    let warmups = 10
    #if DEBUG
    let configuration = "Debug"
    #else
    let configuration = "Release"
    #endif
    let ranking: Distribution
    let queryPipeline: Distribution
    let matchesExpectedResults: Bool
    let catalogPreparation: Preparation
    let system: String
    let lowPowerMode: Bool
    let thermalState: Int
    let panelFirstFrameQualification = "NOT_QUALIFIED"
}
struct Preparation: Encodable {
    let scope = "synthetic fixture construction and Unicode search preparation; excludes indexing and UI"
    let milliseconds: Double
    let normalizedUTF8Bytes: Int
}
struct CachedDiagnosticProvider: CommandProviding {
    let id = "keydock.diagnostics.catalog"
    let items: [CommandItem]
    func commands(matching query: String) async throws -> [CommandItem] { items }
}
func milliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
}
let preparationStarted = ContinuousClock.now
let items = (0..<2_000).map { CommandItem(id: "synthetic.\($0)", title: "Application \($0)", subtitle: "Synthetic fixture", keywords: ["应用", "tool"], kind: .application) }
let preparation = Preparation(milliseconds: milliseconds(preparationStarted.duration(to: .now)), normalizedUTF8Bytes: items.reduce(0) { $0 + $1.preparedSearchTextUTF8Bytes })
let queries = ["Application 12", "应用 tool"], variants = ["application-prefix", "localized-keywords"]
let expected = queries.map { CommandSearch.rank(query: $0, items: items, preferences: .init()).map(\.id) }
var ranking: [Timing] = [], pipeline: [Timing] = []
for index in 0..<110 {
    let variant = index % 2, started = ContinuousClock.now
    let result = CommandSearch.rank(query: queries[variant], items: items, preferences: .init())
    let elapsed = milliseconds(started.duration(to: .now))
    guard result.map(\.id) == expected[variant] else { throw CocoaError(.coderReadCorrupt) }
    if index >= 10 { ranking.append(.init(ordinal: index - 10, variant: variants[variant], milliseconds: elapsed, resultCount: result.count, queryID: nil, generation: nil)) }
}
let coordinator = QueryCoordinator()
for index in 0..<110 {
    let variant = index % 2, started = ContinuousClock.now
    let request = QueryRequest(generation: UInt64(index + 1), text: queries[variant], source: "keydock.synthetic-diagnostics")
    let stream = await coordinator.search(request: request, providers: [CachedDiagnosticProvider(items: items)])
    var first: Timing?, complete = false
    for await batch in stream {
        guard batch.queryID == request.queryID, batch.generation == request.generation, batch.failures.isEmpty else { throw CocoaError(.coderReadCorrupt) }
        if first == nil && (!batch.items.isEmpty || batch.isComplete) {
            let elapsed = milliseconds(started.duration(to: .now))
            guard batch.items.map(\.id) == expected[variant] else { throw CocoaError(.coderReadCorrupt) }
            first = .init(ordinal: index - 10, variant: variants[variant], milliseconds: elapsed, resultCount: batch.items.count, queryID: request.queryID, generation: request.generation)
        }
        complete = complete || batch.isComplete
    }
    guard let first, complete else { throw CocoaError(.coderReadCorrupt) }
    if index >= 10 { pipeline.append(first) }
}
let rankingReport = try Distribution(scope: "synthetic ranking; excludes provider, UI, AX and indexing", samples: ranking)
let pipelineReport = try Distribution(scope: "QueryRequest -> cached Provider -> QueryCoordinator -> first displayable ResultBatch; excludes UI, AX and indexing", samples: pipeline)
let report = Report(ranking: rankingReport, queryPipeline: pipelineReport, matchesExpectedResults: true, catalogPreparation: preparation,
    system: ProcessInfo.processInfo.operatingSystemVersionString, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
    thermalState: ProcessInfo.processInfo.thermalState.rawValue)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(report), as: UTF8.self))
if !rankingReport.pass || !pipelineReport.pass { exit(1) }
