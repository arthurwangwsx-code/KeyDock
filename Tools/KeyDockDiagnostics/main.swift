import Foundation
import CommandCore

// 合成数据性能基线，不读取应用标题、剪贴板或用户文件。
let items = (0..<2000).map { i in
    CommandItem(id: "synthetic.\(i)", title: "Application \(i)", subtitle: "Synthetic fixture", keywords: ["应用", "tool"], kind: .application)
}
var timings: [Double] = []
var count = 0
for index in 0..<110 {
    let started = ContinuousClock.now
    let ranked = CommandSearch.rank(query: index.isMultiple(of: 2) ? "Application 12" : "应用 tool", items: items, preferences: .init())
    count += ranked.count
    let duration = started.duration(to: .now).components
    let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    if index >= 10 { timings.append(milliseconds) }
}
timings.sort()
// 测量生产使用的协调链路，从请求提交到首个可展示结果；不包含窗口绘制。
struct CachedDiagnosticProvider: CommandProviding {
    let id = "keydock.diagnostics.catalog"
    let items: [CommandItem]
    func commands(matching query: String) async throws -> [CommandItem] { items }
}
let coordinator = QueryCoordinator()
var pipelineTimings: [Double] = []
var pipelineChecksum = 0
for index in 0..<110 {
    let started = ContinuousClock.now
    let request = QueryRequest(generation: UInt64(index + 1), text: index.isMultiple(of: 2) ? "Application 12" : "应用 tool", source: "keydock.synthetic-diagnostics")
    let stream = await coordinator.search(request: request, providers: [CachedDiagnosticProvider(items: items)])
    var first: Duration?
    for await batch in stream {
        if first == nil && (!batch.items.isEmpty || batch.isComplete) {
            first = started.duration(to: .now); pipelineChecksum += batch.items.count
        }
    }
    guard let first else { throw CocoaError(.coderReadCorrupt) }
    if index >= 10 {
        let components = first.components
        pipelineTimings.append(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
pipelineTimings.sort()
let report: [String: Any] = [
    "scope": "synthetic cached ranking only; excludes panel/AX/indexing",
    "samples": timings.count, "items": items.count,
    "p50Milliseconds": timings[49], "p95Milliseconds": timings[94],
    "maxMilliseconds": timings.last ?? 0,
    "p95TargetMilliseconds": 50, "pass": timings[94] <= 50,
    "resultChecksum": count,
    "system": ProcessInfo.processInfo.operatingSystemVersionString,
    "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
    "queryPipeline": [
        "scope": "QueryRequest -> cached Provider -> QueryCoordinator -> first displayable ResultBatch; excludes UI/AX/indexing",
        "samples": pipelineTimings.count, "warmups": 10, "items": items.count,
        "p50Milliseconds": pipelineTimings[49], "p95Milliseconds": pipelineTimings[94],
        "maxMilliseconds": pipelineTimings.last ?? 0, "p95TargetMilliseconds": 50,
        "pass": pipelineTimings[94] <= 50, "resultChecksum": pipelineChecksum,
        "matchesRankingChecksum": pipelineChecksum == count
    ]
]
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: output, as: UTF8.self))

if timings[94] > 50 || pipelineTimings[94] > 50 || pipelineChecksum != count { exit(1) }
