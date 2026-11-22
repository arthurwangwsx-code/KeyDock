import Foundation
import Darwin
import Testing

private final class AIRecoveryProbeAnchor: NSObject {}

/// 单独的无 UI probe，采用有界 POSIX 清理；不能杀主 App 或其它测试进程。
final class AIRecoveryProbeProcess {
    let runID: UUID
    private let lock = NSLock()
    private var childPID: pid_t = 0
    private var outputFD: Int32 = -1

    init(directory: URL, endpoint: String, mode: String) throws {
        let executable = try Self.locateExecutable()
        let child = try Self.spawn(executable, arguments: [directory.path, endpoint, mode])
        do {
            runID = try Self.readRunID(child.output)
            childPID = child.pid; outputFD = child.output
        } catch {
            _ = Self.terminate(child.pid)
            Darwin.close(child.output)
            throw error
        }
    }
    deinit { stop() }
    func stop() {
        // stop/deinit 可重复进入，但同一个 pid/fd 只允许被当前 owner 收口一次。
        lock.lock()
        let pid = childPID, descriptor = outputFD
        childPID = 0; outputFD = -1
        lock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
        if pid > 0 && !Self.terminate(pid) { Issue.record("Synthetic SSE fixture did not exit within its cleanup deadline") }
    }
    func killForCrash() throws {
        guard childPID > 0, !Self.reaped(childPID) else { throw StoreHTTPError.startupFailed }
        let pid = childPID
        guard Darwin.kill(pid, SIGKILL) == 0 else { throw StoreHTTPError.startupFailed }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        repeat {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                childPID = 0
                guard status & 0x7f == SIGKILL else { throw StoreHTTPError.startupFailed }
                return
            }
            usleep(10_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw StoreHTTPError.timedOut
    }
    private static func locateExecutable() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["KEYDOCK_AI_RECOVERY_PROBE"],
           FileManager.default.isExecutableFile(atPath: explicit) { return URL(fileURLWithPath: explicit) }
        var roots = [Bundle(for: AIRecoveryProbeAnchor.self).bundleURL,
                     URL(fileURLWithPath: #filePath).deletingLastPathComponent()]
        if let executable = Bundle.main.executableURL { roots.append(executable.deletingLastPathComponent()) }
        for root in roots {
            var folder = root
            for _ in 0..<9 {
                for suffix in ["KeyDockAIRecoveryProbe", ".build/debug/KeyDockAIRecoveryProbe"] {
                    let candidate = folder.appendingPathComponent(suffix)
                    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                }
                let parent = folder.deletingLastPathComponent()
                if parent == folder { break }
                folder = parent
            }
        }
        throw StoreHTTPError.missingScript
    }
    private static func readRunID(_ descriptor: Int32) throws -> UUID {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        var bytes = Data()
        while bytes.count < 64 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw StoreHTTPError.startupFailed }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let milliseconds = Int32(min((deadline - now) / 1_000_000, 5000))
            let ready = Darwin.poll(&item, 1, milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw StoreHTTPError.startupFailed }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw StoreHTTPError.startupFailed }
            if byte == 10 {
                guard let value = UUID(uuidString: String(decoding: bytes, as: UTF8.self)) else { throw StoreHTTPError.startupFailed }
                return value
            }
            bytes.append(byte)
        }
        throw StoreHTTPError.startupFailed
    }
    private static func spawn(_ executable: URL, arguments childArguments: [String]) throws -> (pid: pid_t, output: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw StoreHTTPError.startupFailed }
        defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO))
        for fd in descriptors { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        try check(posix_spawnattr_setflags(&attributes, flags))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let argumentStrings: [String] = [executable.path] + childArguments
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        arguments.append(nil); environment.append(nil)
        defer {
            for case let pointer? in arguments { free(pointer) }
            for case let pointer? in environment { free(pointer) }
        }
        var pid: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, executable.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(result)
        Darwin.close(descriptors[1]); descriptors[1] = -1
        let output = descriptors[0]; descriptors[0] = -1
        return (pid, output)
    }
    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw StoreHTTPError.startupFailed }
    }
    private static func terminate(_ pid: pid_t) -> Bool {
        // 不使用 Foundation Process.waitUntilExit；只回收本 helper 创建且仍拥有的子进程。
        if reaped(pid) { return true }
        _ = Darwin.kill(pid, SIGTERM)
        if pollExit(pid, milliseconds: 1000) { return true }
        _ = Darwin.kill(pid, SIGKILL)
        return pollExit(pid, milliseconds: 1000)
    }
    private static func pollExit(_ pid: pid_t, milliseconds: UInt64) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
        repeat {
            if reaped(pid) { return true }
            usleep(10_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return reaped(pid)
    }
    private static func reaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        // ECHILD 表示已不再拥有可回收子进程，绝不继续向可能重用的 pid 发信号。
        return result == pid || (result < 0 && errno == ECHILD)
    }
}
