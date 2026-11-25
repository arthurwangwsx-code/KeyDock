import Foundation
import Darwin
@testable import WorkbenchFeature

enum TaskMaterialTestFixtures {
    static func directory(_ label: String) throws -> URL {
        // 只规范测试来源；生产文件层不接受用路径解析绕过no-follow。
        let raw = ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
        guard let physical = realpath(raw, nil) else { throw TaskMaterialError.unavailable }
        defer { free(physical) }
        let url = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent("KeyDock-Material-" + label + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func key() -> TaskMaterialKey { .init(receiptStore: .ai, invocationID: UUID(), receiptRecordIdentity: UUID()) }
    static var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }
}
