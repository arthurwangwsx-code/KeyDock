import AppKit
import Foundation

// 安装辅助工具只查询身份与请求正常退出，不接触窗口、权限或用户数据。
private enum LifecycleFailure: Error {
    case usage(String)
    case refused(String)
}

private struct Options {
    enum Operation: String { case status, quit }
    let operation: Operation
    let bundleID: String
    let allowedPaths: Set<String>
    let timeout: TimeInterval

    static func parse(_ arguments: [String]) throws -> Options {
        guard let first = arguments.first, let operation = Operation(rawValue: first) else {
            throw LifecycleFailure.usage("Expected status or quit.")
        }
        var bundleID: String?
        var allowedPaths: Set<String> = []
        var timeout: TimeInterval = 20
        var receivedTimeout = false
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw LifecycleFailure.usage("Missing value for \(option).")
            }
            let value = arguments[index + 1]
            switch option {
            case "--bundle-id":
                guard bundleID == nil else { throw LifecycleFailure.usage("Duplicate --bundle-id.") }
                bundleID = value
            case "--allowed-path":
                guard operation == .quit else {
                    throw LifecycleFailure.usage("--allowed-path is valid only for quit.")
                }
                allowedPaths.insert(try canonicalAllowedPath(value))
            case "--timeout":
                guard operation == .quit, !receivedTimeout,
                      let parsed = TimeInterval(value), parsed.isFinite, parsed > 0, parsed <= 20 else {
                    throw LifecycleFailure.usage("--timeout must occur once and be greater than 0 and at most 20 seconds.")
                }
                timeout = parsed
                receivedTimeout = true
            default:
                throw LifecycleFailure.usage("Unknown option: \(option).")
            }
            index += 2
        }
        guard let bundleID, ["com.arthurwangwsx.KeyDock", "com.arthurwangwsx.KeyDock.preview"].contains(bundleID) else {
            throw LifecycleFailure.usage("Only the KeyDock production and preview bundle identifiers are supported.")
        }
        guard operation != .quit || !allowedPaths.isEmpty else {
            throw LifecycleFailure.usage("quit requires at least one --allowed-path.")
        }
        return Options(operation: operation, bundleID: bundleID, allowedPaths: allowedPaths, timeout: timeout)
    }

    private static func canonicalAllowedPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw LifecycleFailure.usage("--allowed-path must be an absolute app bundle path.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.pathExtension.lowercased() == "app" else {
            throw LifecycleFailure.usage("--allowed-path must identify an .app bundle.")
        }
        return canonical.path
    }
}

private struct LifecycleReport: Encodable {
    let bundleID: String
    let processes: [ProcessReport]

    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", processes }
}

private struct ProcessReport: Encodable {
    let pid: Int32
    let bundleID: String?
    let bundlePath: String?
    let running: Bool
    let termination: String

    enum CodingKeys: String, CodingKey {
        case pid, bundleID = "bundle_id", bundlePath = "path", running, termination
    }

    // 缺少身份字段必须明确输出 null，不能静默略去。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        if let bundleID { try container.encode(bundleID, forKey: .bundleID) }
        else { try container.encodeNil(forKey: .bundleID) }
        if let bundlePath { try container.encode(bundlePath, forKey: .bundlePath) }
        else { try container.encodeNil(forKey: .bundlePath) }
        try container.encode(running, forKey: .running)
        try container.encode(termination, forKey: .termination)
    }
}

@MainActor private enum Lifecycle {
    private struct Target {
        let application: NSRunningApplication
        let bundleID: String?
        let path: String?
        let canonicalPath: String?
        let launchDate: Date?
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let options = try Options.parse(arguments)
            let targets = matching(options.bundleID)
            if options.operation == .status {
                try write(targets.map { report($0, termination: "not_requested") }, bundleID: options.bundleID)
                return 0
            }
            // 任一身份未知都先整批拒绝，禁止对已知子集部分退出。
            guard targets.allSatisfy({ target in
                target.bundleID == options.bundleID &&
                target.canonicalPath.map(options.allowedPaths.contains) == true
            }) else {
                try write(targets.map { report($0, termination: "not_requested") }, bundleID: options.bundleID)
                throw LifecycleFailure.refused("A matching process has an unknown or unapproved bundle path; no termination requests were sent.")
            }

            let deadline = ProcessInfo.processInfo.systemUptime + options.timeout
            var results: [Int32: String] = [:]
            for target in targets {
                let application = target.application
                if application.isTerminated {
                    results[application.processIdentifier] = "already_terminated"
                } else {
                    results[application.processIdentifier] = application.terminate() ? "requested" : "terminate_rejected"
                }
            }

            // isTerminated 的更新依赖主 RunLoop；定时器避免无事件源时空转。
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            defer { timer.invalidate() }
            while targets.contains(where: { !$0.application.isTerminated }) {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.05, remaining)))
            }

            var output = targets.map { target in
                let pid = target.application.processIdentifier
                let initial = results[pid] ?? "not_requested"
                let final: String
                if target.application.isTerminated {
                    final = initial == "already_terminated" ? initial : "terminated"
                } else {
                    final = initial == "terminate_rejected" ? initial : "timed_out"
                }
                return report(target, termination: final)
            }
            // 等待期间新出现的实例只报告，不给新实例补发退出请求。
            let newTargets = matching(options.bundleID).filter { current in
                !current.application.isTerminated && !targets.contains(where: { original in
                    !original.application.isTerminated &&
                    original.application.processIdentifier == current.application.processIdentifier &&
                    original.launchDate == current.launchDate && original.canonicalPath == current.canonicalPath
                })
            }
            output.append(contentsOf: newTargets.map { report($0, termination: "not_requested_new_process") })
            output.sort { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
                return lhs.termination < rhs.termination
            }
            try write(output, bundleID: options.bundleID)
            guard !output.contains(where: \.running) else {
                throw LifecycleFailure.refused("One or more matching processes are still running; no forced termination was attempted.")
            }
            return 0
        } catch LifecycleFailure.usage(let message) {
            writeError(message + "\nUsage: KeyDockLifecycle status --bundle-id BID\n       KeyDockLifecycle quit --bundle-id BID --allowed-path APP [--allowed-path APP] [--timeout 20]\n")
            return 64
        } catch LifecycleFailure.refused(let message) {
            writeError(message + "\n")
            return 1
        } catch {
            writeError("Lifecycle command failed: \(error.localizedDescription)\n")
            return 70
        }
    }

    private static func matching(_ bundleID: String) -> [Target] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .sorted { $0.processIdentifier < $1.processIdentifier }
            .map { application in
                let url = application.bundleURL.flatMap { $0.isFileURL ? $0.absoluteURL : nil }
                let canonicalPath = url?.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
                return Target(application: application, bundleID: application.bundleIdentifier,
                    path: url?.path, canonicalPath: canonicalPath, launchDate: application.launchDate)
            }
    }

    private static func report(_ target: Target, termination: String) -> ProcessReport {
        ProcessReport(pid: target.application.processIdentifier,
            bundleID: target.bundleID, bundlePath: target.path,
            running: !target.application.isTerminated, termination: termination)
    }

    private static func write(_ reports: [ProcessReport], bundleID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(LifecycleReport(bundleID: bundleID, processes: reports))
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func writeError(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }
}

exit(Lifecycle.run(arguments: Array(CommandLine.arguments.dropFirst())))
