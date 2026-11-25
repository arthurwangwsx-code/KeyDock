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
        .library(name: "AutomationCore", targets: ["AutomationCore"]),
        .library(name: "MCPAdapters", targets: ["MCPAdapters"]),
        .library(name: "MacAdapters", targets: ["MacAdapters"]),
        .library(name: "WorkbenchFeature", targets: ["WorkbenchFeature"]),
        .library(name: "KeyDockUI", targets: ["KeyDockUI"]),
        .executable(name: "KeyDockDiagnostics", targets: ["KeyDockDiagnostics"]),
        .executable(name: "KeyDockProcessProbe", targets: ["KeyDockProcessProbe"]),
        .executable(name: "KeyDockAIRecoveryProbe", targets: ["KeyDockAIRecoveryProbe"]),
        .executable(name: "KeyDockMCPInteropProbe", targets: ["KeyDockMCPInteropProbe"])
    ],
    targets: [
        .target(name: "CommandCore", path: "Packages/CommandCore/Sources/CommandCore"),
        .target(name: "ExecutionCore", path: "Packages/ExecutionCore/Sources/ExecutionCore"),
        .target(name: "AICore", path: "Packages/AICore/Sources/AICore"),
        .target(name: "AutomationCore", path: "Packages/AutomationCore/Sources/AutomationCore"),
        .target(name: "MCPAdapters", dependencies: ["AICore", "AgentCore"], path: "Packages/MCPAdapters/Sources/MCPAdapters"),
        .testTarget(name: "MCPAdaptersTests", dependencies: ["MCPAdapters", "AICore"], path: "Packages/MCPAdapters/Tests/MCPAdaptersTests", exclude: ["mcp_http_fixture.py", "mcp_stdio_fixture.py"]),
        .testTarget(name: "AutomationCoreTests", dependencies: ["AutomationCore"], path: "Packages/AutomationCore/Tests/AutomationCoreTests"),
        .executableTarget(name: "KeyDockDiagnostics", dependencies: ["CommandCore"], path: "Tools/KeyDockDiagnostics"),
        .executableTarget(name: "KeyDockProcessProbe", path: "Tools/KeyDockProcessProbe"),
        .executableTarget(name: "KeyDockAIRecoveryProbe", dependencies: ["WorkbenchFeature"], path: "Tools/KeyDockAIRecoveryProbe"),
        .executableTarget(name: "KeyDockMCPInteropProbe", dependencies: ["MCPAdapters", "AICore"], path: "Tools/KeyDockMCPInteropProbe"),
        .target(name: "AgentCore", dependencies: ["AICore", "ExecutionCore"], path: "Packages/AgentCore/Sources/AgentCore"),
        .systemLibrary(name: "CSQLite", path: "Packages/CSQLite"),
        .target(name: "MacAdapters", dependencies: ["CommandCore", "ExecutionCore", "CSQLite"], path: "Packages/MacAdapters/Sources/MacAdapters"),
        .target(name: "KeyDockUI", path: "Packages/KeyDockUI/Sources/KeyDockUI"),
        .target(name: "WorkbenchFeature", dependencies: ["CommandCore", "ExecutionCore", "AICore", "AgentCore", "AutomationCore", "MCPAdapters", "MacAdapters", "KeyDockUI"], path: "Packages/WorkbenchFeature/Sources/WorkbenchFeature", resources: [.process("Resources")]),
        .testTarget(name: "CommandCoreTests", dependencies: ["CommandCore"], path: "Packages/CommandCore/Tests/CommandCoreTests"),
        .testTarget(name: "ExecutionCoreTests", dependencies: ["ExecutionCore"], path: "Packages/ExecutionCore/Tests/ExecutionCoreTests"),
        .testTarget(name: "AICoreTests", dependencies: ["AICore", "AgentCore"], path: "Packages/AICore/Tests/AICoreTests"),
        .testTarget(name: "WorkbenchFeatureTests", dependencies: ["WorkbenchFeature", "AutomationCore", "CommandCore", "ExecutionCore", "AICore", "KeyDockUI", "MacAdapters", "KeyDockAIRecoveryProbe"], path: "Packages/WorkbenchFeature/Tests/WorkbenchFeatureTests"),
        .testTarget(name: "MacAdaptersTests", dependencies: ["MacAdapters", "CSQLite"], path: "Packages/MacAdapters/Tests/MacAdaptersTests")
    ]
)
