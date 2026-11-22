import Foundation
import WorkbenchFeature

/// 测试专用进程：只接受合成目录和 loopback endpoint，不访问桌面上下文或凭据。
@main struct KeyDockAIRecoveryProbe {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4,
              let endpoint = URL(string: CommandLine.arguments[2]),
              endpoint.scheme == "http", endpoint.host == "127.0.0.1" else { throw CocoaError(.coderInvalidValue) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard directory.lastPathComponent.hasPrefix("KeyDock-AI-Crash-") else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw CocoaError(.fileWriteFileExists) }
        var configuration = AppConfiguration()
        var action = AIActionPreset(name: "synthetic-sensitive-custom-action-title", prompt: "synthetic-sensitive-AI-prompt")
        action.input = .manual; action.output = .copy
        configuration.endpoint = endpoint.absoluteString; configuration.localHTTP = true
        configuration.model = "synthetic-crash-model"; configuration.aiActions = [action]
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"))
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in try? Data("unexpected".utf8).write(to: directory.appendingPathComponent("unexpected-copy")) },
            clipboardChangeCount: { 0 })
        let draft = store.createDraft(input: "synthetic-sensitive-AI-input")
        switch CommandLine.arguments[3] {
        case "text": _ = store.runAI(action: action, draft: draft)
        case "proposal": store.generateCommandProposal(draft: draft)
        case "agent": store.runReadOnlyAgent(draft: draft)
        default: throw CocoaError(.coderInvalidValue)
        }
        guard let id = store.tasks.first?.id else { throw CocoaError(.coderInvalidValue) }
        try FileHandle.standardOutput.write(contentsOf: Data((id.uuidString + "\n").utf8))
        // 父测试在真实 HTTP 已开始后 SIGKILL；不安装 signal handler，也不走正常 shutdown。
        while true { try await Task.sleep(for: .seconds(1)) }
    }
}
