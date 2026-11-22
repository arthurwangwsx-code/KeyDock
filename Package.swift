// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyDockModules",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CommandCore", targets: ["CommandCore"]),
        .library(name: "ExecutionCore", targets: ["ExecutionCore"]),
        .library(name: "AICore", targets: ["AICore"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "MacAdapters", targets: ["MacAdapters"]),
        .library(name: "WorkbenchFeature", targets: ["WorkbenchFeature"]),
        .library(name: "KeyDockUI", targets: ["KeyDockUI"]),
        .executable(name: "KeyDockDiagnostics", targets: ["KeyDockDiagnostics"])
    ],
    targets: [
        .target(name: "CommandCore", path: "Packages/CommandCore/Sources/CommandCore"),
        .target(name: "ExecutionCore", path: "Packages/ExecutionCore/Sources/ExecutionCore"),
        .target(name: "AICore", path: "Packages/AICore/Sources/AICore"),
        .executableTarget(name: "KeyDockDiagnostics", dependencies: ["CommandCore"], path: "Tools/KeyDockDiagnostics"),
        .target(name: "AgentCore", dependencies: ["AICore", "ExecutionCore"], path: "Packages/AgentCore/Sources/AgentCore"),
        .systemLibrary(name: "CSQLite", path: "Packages/CSQLite"),
        .target(name: "MacAdapters", dependencies: ["CommandCore", "CSQLite"], path: "Packages/MacAdapters/Sources/MacAdapters"),
        .target(name: "KeyDockUI", path: "Packages/KeyDockUI/Sources/KeyDockUI"),
        .target(name: "WorkbenchFeature", dependencies: ["CommandCore", "ExecutionCore", "AICore", "AgentCore", "MacAdapters", "KeyDockUI"], path: "Packages/WorkbenchFeature/Sources/WorkbenchFeature", resources: [.process("Resources")]),
        .testTarget(name: "CommandCoreTests", dependencies: ["CommandCore"], path: "Packages/CommandCore/Tests/CommandCoreTests"),
        .testTarget(name: "ExecutionCoreTests", dependencies: ["ExecutionCore"], path: "Packages/ExecutionCore/Tests/ExecutionCoreTests"),
        .testTarget(name: "AICoreTests", dependencies: ["AICore", "AgentCore"], path: "Packages/AICore/Tests/AICoreTests"),
        .testTarget(name: "WorkbenchFeatureTests", dependencies: ["WorkbenchFeature", "CommandCore", "ExecutionCore", "KeyDockUI"], path: "Packages/WorkbenchFeature/Tests/WorkbenchFeatureTests"),
        .testTarget(name: "MacAdaptersTests", dependencies: ["MacAdapters"], path: "Packages/MacAdapters/Tests/MacAdaptersTests")
    ]
)
