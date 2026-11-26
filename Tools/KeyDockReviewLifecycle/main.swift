import AppKit
import Foundation

/// 仅配对的本地Review身份；请求退出前复核PID、出生时间和可执行路径，不强制终止。
@main @MainActor enum KeyDockReviewLifecycle {
    struct Identity: Codable, Equatable {
        let pid: Int32
        let birth: Double
        let bundleID: String
        let path: String
        let executablePath: String
    }
    enum Failure: Error { case refused }
    static func identity(_ app: NSRunningApplication) throws -> Identity {
        guard !app.isTerminated, let birth = app.launchDate?.timeIntervalSince1970, birth.isFinite, birth > 0,
              let bid = app.bundleIdentifier, let path = app.bundleURL?.path, let executable = app.executableURL?.path else { throw Failure.refused }
        return .init(pid: app.processIdentifier, birth: birth, bundleID: bid, path: path, executablePath: executable)
    }
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3 || args.count == 5, ["probe", "quit"].contains(args[0]),
                  ["com.arthurwangwsx.KeyDock.desktopreview", "com.arthurwangwsx.KeyDock.desktopreview.fixture"].contains(args[1]),
                  args[2].hasPrefix("/"), !args[2].split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Failure.refused }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).filter { !$0.isTerminated }
            let identities = try apps.map(identity)
            guard identities.allSatisfy({ $0.path == args[2] }) else { throw Failure.refused }
            if args[0] == "quit" {
                guard args.count == 5, let pid = Int32(args[3]), let birth = Double(args[4]), birth.isFinite, birth > 0,
                      identities.count <= 1 else { throw Failure.refused }
                if let current = identities.first, let app = apps.first {
                    guard current.pid == pid, current.birth == birth, try identity(app) == current else { throw Failure.refused }
                    guard app.terminate() else { throw Failure.refused }
                    let timer = Timer(timeInterval: 0.05, repeats: true) { _ in }
                    RunLoop.current.add(timer, forMode: .default); defer { timer.invalidate() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 15
                    while !app.isTerminated && ProcessInfo.processInfo.systemUptime < deadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
                    guard app.isTerminated else { throw Failure.refused }
                }
                guard NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).allSatisfy(\.isTerminated) else { throw Failure.refused }
            } else { guard args.count == 3 else { throw Failure.refused } }
            let data = try JSONEncoder().encode(args[0] == "probe" ? identities : [])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        } catch { FileHandle.standardError.write(Data("Review lifecycle refused; no forced termination was attempted.\n".utf8)); exit(1) }
    }
}
