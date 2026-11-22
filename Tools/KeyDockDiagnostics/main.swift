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
let report: [String: Any] = [
    "scope": "synthetic cached ranking only; excludes panel/AX/indexing",
    "samples": timings.count, "items": items.count,
    "p50Milliseconds": timings[49], "p95Milliseconds": timings[94],
    "maxMilliseconds": timings.last ?? 0,
    "p95TargetMilliseconds": 50, "pass": timings[94] <= 50,
    "resultChecksum": count,
    "system": ProcessInfo.processInfo.operatingSystemVersionString
]
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: output, as: UTF8.self))
