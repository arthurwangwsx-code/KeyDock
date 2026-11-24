import Darwin
import Dispatch
import Foundation

/// 一次性命令的生命周期所有者；交互命令应交给终端 adapter。
public actor ProcessRunner {
    private var sessions: [UUID: ProcessSession] = [:]
    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let outputLimitBytes: Int

    public init(outputLimitBytes: Int = 1_048_576) {
        self.outputLimitBytes = min(16_777_216, max(1, outputLimitBytes))
    }

    public func run(_ command: SavedCommand, id: UUID) -> AsyncStream<ProcessEvent> {
        let pair = AsyncStream<ProcessEvent>.makeStream()
        guard sessions[id] == nil else {
            pair.continuation.yield(.finished(.init(state: .failed, message: "process.duplicateInvocation")))
            pair.continuation.finish()
            return pair.stream
        }
        guard sessions.count < 8 else {
            pair.continuation.yield(.finished(.init(state: .failed, message: "process.capacityExceeded")))
            pair.continuation.finish()
            return pair.stream
        }
        let session = ProcessSession(command: command, continuation: pair.continuation, outputLimit: outputLimitBytes)
        sessions[id] = session
        pair.continuation.onTermination = { @Sendable [weak session] termination in
            if case .cancelled = termination { session?.requestStop(.cancelled) }
        }
        if Task.isCancelled { session.requestStop(.cancelled) }
        session.start { [weak self] in
            Task { await self?.remove(id) }
        }
        return pair.stream
    }

    public func cancel(_ id: UUID) {
        sessions[id]?.requestStop(.cancelled)
    }

    /// 取消流后仍等待真实worker回收，避免把Swift任务取消误报为进程已退出。
    public func waitForCompletion(_ id: UUID) async {
        guard sessions[id] != nil else { return }
        await withCheckedContinuation { continuation in completionWaiters[id,default:[]].append(continuation) }
    }

    private func remove(_ id: UUID) {
        sessions[id] = nil
        let waiters = completionWaiters.removeValue(forKey:id) ?? []
        for waiter in waiters { waiter.resume() }
    }

    deinit {
        for session in sessions.values { session.requestStop(.cancelled) }
    }
}

/// 只有 stop 标志跨线程访问；pid、fd、回收与信号全部由专用 worker 串行拥有。
private final class ProcessSession: @unchecked Sendable {
    private let command: SavedCommand
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let outputLimit: Int
    private let lock = NSLock()
    private var stopReason: ExecutionState?

    init(command: SavedCommand, continuation: AsyncStream<ProcessEvent>.Continuation, outputLimit: Int) {
        self.command = command
        self.continuation = continuation
        self.outputLimit = outputLimit
    }

    func requestStop(_ reason: ExecutionState) {
        lock.lock()
        if stopReason == nil { stopReason = reason }
        lock.unlock()
    }

    private var requestedStop: ExecutionState? {
        lock.lock()
        defer { lock.unlock() }
        return stopReason
    }

    func start(completion: @escaping @Sendable () -> Void) {
        DispatchQueue(label: "KeyDock.Process", qos: .utility).async { [self] in
            execute()
            completion()
        }
    }

    private func execute() {
        if let reason = requestedStop {
            finish(.init(state: reason, message: "process.cancelled"))
            return
        }
        guard !command.interactive else {
            finish(.init(state: .failed, message: "process.requiresTerminal"))
            return
        }
        do { try command.validate() }
        catch { finish(.init(state: .failed, message: "process.invalidConfiguration")); return }
        do {
            let child = try spawn()
            continuation.yield(.started(child.pid))
            monitor(child)
        } catch let error as SpawnFailure {
            if error.code == ECANCELED, let reason = requestedStop {
                finish(.init(state: reason, message: "process.cancelled"))
            } else {
                finish(.init(state: .failed, exitCode: nil, message: "process.spawnFailed.\(error.code)"))
            }
        } catch {
            finish(.init(state: .failed, message: "process.spawnFailed"))
        }
    }

    private struct Child {
        let pid: pid_t
        let stdout: Int32
        let stderr: Int32
    }
    private struct SpawnFailure: Error { let code: Int32 }

    private func spawn() throws -> Child {
        var out = try makePipe()
        defer { for fd in out where fd >= 0 { Darwin.close(fd) } }
        var err = try makePipe()
        defer { for fd in err where fd >= 0 { Darwin.close(fd) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))
        for fd in out + err { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, command.workingDirectory))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, command.workingDirectory))
        }
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        try check(posix_spawnattr_setflags(&attributes, flags))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        // 不继承宿主完整环境，避免把宿主凭据隐式注入命令。
        var environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(), "USER": NSUserName(),
            "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()
        ]
        environment.merge(command.environment) { _, explicit in explicit }
        let env = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        var pid: pid_t = 0
        // 取消和 spawn 的交界由锁保护，取消已生效时不再启动进程。
        lock.lock()
        if stopReason != nil {
            lock.unlock()
            throw SpawnFailure(code: ECANCELED)
        }
        let status = withCStringArray([command.executable] + command.arguments) { argv in
            withCStringArray(env) { envp in
                posix_spawn(&pid, command.executable, &actions, &attributes, argv, envp)
            }
        }
        lock.unlock()
        try check(status)
        Darwin.close(out[1]); out[1] = -1
        Darwin.close(err[1]); err[1] = -1
        let stdout = out[0], stderr = err[0]
        out[0] = -1; err[0] = -1
        return Child(pid: pid, stdout: stdout, stderr: stderr)
    }

    private func makePipe() throws -> [Int32] {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { throw SpawnFailure(code: errno) }
        do {
            for index in fds.indices {
                if fds[index] < 3 {
                    let duplicate = fcntl(fds[index], F_DUPFD_CLOEXEC, 3)
                    guard duplicate >= 0 else { throw SpawnFailure(code: errno) }
                    Darwin.close(fds[index]); fds[index] = duplicate
                }
                guard fcntl(fds[index], F_SETFD, FD_CLOEXEC) == 0 else { throw SpawnFailure(code: errno) }
            }
            guard fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0 else { throw SpawnFailure(code: errno) }
            return fds
        } catch {
            for fd in fds { Darwin.close(fd) }
            throw error
        }
    }

    private func check(_ code: Int32) throws {
        if code != 0 { throw SpawnFailure(code: code) }
    }

    private func withCStringArray<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        let allocated = strings.map { strdup($0) }
        defer { for pointer in allocated { free(pointer) } }
        return (allocated + [nil]).withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private func monitor(_ child: Child) {
        var fds = [child.stdout, child.stderr]
        defer { for fd in fds where fd >= 0 { Darwin.close(fd) } }
        var decoders = [UTF8ChunkDecoder(), UTF8ChunkDecoder()]
        var emittedBytes = [0, 0]
        var didTruncate = false
        var exitObservedAt: UInt64?
        var termSentAt: UInt64?
        var killSent = false
        var waitFailed = false
        var drainIncomplete = false
        let started = DispatchTime.now().uptimeNanoseconds

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if Double(now - started) / 1_000_000_000 >= command.timeout { requestStop(.timedOut) }
            if requestedStop != nil && termSentAt == nil && !waitFailed {
                // pid 尚未回收，进程组号不会因 PID 重用指向无关进程。
                Darwin.kill(-child.pid, SIGTERM)
                termSentAt = now
            }
            if let termSentAt, !killSent, now - termSentAt >= 300_000_000, !waitFailed {
                Darwin.kill(-child.pid, SIGKILL)
                killSent = true
            }

            for index in fds.indices where fds[index] >= 0 {
                var reads = 0
                while reads < 16 {
                    var bytes = [UInt8](repeating: 0, count: 8_192)
                    let count = Darwin.read(fds[index], &bytes, bytes.count)
                    if count > 0 {
                        reads += 1
                        // 为两条流分别保留预算，避免 stdout 抢完容量后丢失全部错误信息。
                        let streamLimit = index == 0 ? (outputLimit + 1) / 2 : outputLimit / 2
                        let remaining = max(0, streamLimit - emittedBytes[index])
                        let accepted = min(remaining, count)
                        if accepted > 0 {
                            emittedBytes[index] += accepted
                            let text = decoders[index].append(Array(bytes.prefix(accepted)))
                            if !text.isEmpty { continuation.yield(.output(text, isError: index == 1)) }
                        }
                        if accepted < count && !didTruncate {
                            didTruncate = true
                            continuation.yield(.output("\n[process.outputTruncated]\n", isError: true))
                        }
                    } else if count == 0 {
                        let tail = decoders[index].finish()
                        if !tail.isEmpty { continuation.yield(.output(tail, isError: index == 1)) }
                        Darwin.close(fds[index]); fds[index] = -1
                        break
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else {
                        Darwin.close(fds[index]); fds[index] = -1
                        drainIncomplete = true
                        break
                    }
                }
            }

            if exitObservedAt == nil && !waitFailed {
                var info = siginfo_t()
                let status = waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOWAIT | WNOHANG)
                if status == 0 && info.si_pid == child.pid {
                    exitObservedAt = now
                    // 一次性任务不让仍在本组的后代变成后台残留。
                    Darwin.kill(-child.pid, SIGTERM)
                    termSentAt = termSentAt ?? now
                } else if status != 0 && errno != EINTR {
                    // wait ownership 已丢失时不再向可能重用的 pid/pgid 发信号。
                    waitFailed = true
                    exitObservedAt = now
                }
            }
            if let exitObservedAt {
                if fds.allSatisfy({ $0 < 0 }) { break }
                if now - exitObservedAt >= 1_000_000_000 {
                    drainIncomplete = true
                    break
                }
            }
            var watched = fds.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0) }
            _ = watched.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), 20) }
        }
        if !waitFailed { Darwin.kill(-child.pid, SIGKILL) }
        var status: Int32 = 0
        var waited: pid_t = -1
        if !waitFailed {
            repeat { waited = waitpid(child.pid, &status, 0) } while waited < 0 && errno == EINTR
        }
        let normalExit = (status & 0x7f) == 0
        let code: Int32? = waited == child.pid ? (normalExit ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : nil
        if let reason = requestedStop {
            finish(.init(state: reason, exitCode: code, message: reason == .timedOut ? "process.timedOut" : "process.cancelled"))
        } else if waitFailed || waited != child.pid {
            finish(.init(state: .interrupted, message: "process.waitFailed"))
        } else if drainIncomplete {
            finish(.init(state: .failed, exitCode: code, message: "process.outputDrainIncomplete"))
        } else {
            finish(.init(state: normalExit && code == 0 ? .succeeded : .failed, exitCode: code, message: normalExit ? "process.exited" : "process.signalled"))
        }
    }

    private func finish(_ result: ProcessResult) {
        continuation.yield(.finished(result))
        continuation.finish()
    }
}

/// 保留跨 read 的不完整 UTF-8 尾部；无效字节仍用替代字符显示。
private struct UTF8ChunkDecoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        let combined = pending + bytes
        pending = []
        guard !combined.isEmpty else { return "" }
        var start = combined.count - 1
        while start > 0 && combined[start] & 0xc0 == 0x80 && combined.count - start < 4 { start -= 1 }
        let lead = combined[start]
        let expected = lead & 0xf8 == 0xf0 ? 4 : lead & 0xf0 == 0xe0 ? 3 : lead & 0xe0 == 0xc0 ? 2 : 1
        if expected > combined.count - start {
            pending = Array(combined[start...])
            return String(decoding: combined[..<start], as: UTF8.self)
        }
        return String(decoding: combined, as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}
