import Foundation
import Darwin

private final class MCPWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// 只拥有本次posix_spawn产生的pid/fd。没有权限隔离，也不读取shell环境与历史。
final class MCPStdioProcess: @unchecked Sendable {
    let incomingLines: AsyncThrowingStream<Data, Error>
    private let pid: pid_t
    private var input: Int32
    private let state = NSLock(), writer = NSLock()
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var buffer = Data()
    private var closed = false, outputEnded = false, reaped = false, forced = false
    private var stderrCount = 0, stdoutCount = 0

    init(_ configuration: MCPStdioLaunchConfiguration) throws {
        try configuration.validate()
        let child = try Self.spawn(configuration)
        pid = child.pid; input = child.input
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        incomingLines = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { captured = $0 }
        continuation = captured
        let queue = DispatchQueue(label: "KeyDock.MCP.Stdio.\(child.pid)", qos: .utility)
        let output = DispatchSource.makeReadSource(fileDescriptor: child.output, queue: queue)
        let errors = DispatchSource.makeReadSource(fileDescriptor: child.error, queue: queue)
        output.setEventHandler { [weak self] in self?.read(child.output, stderr: false) }
        errors.setEventHandler { [weak self] in self?.read(child.error, stderr: true) }
        output.setCancelHandler { Darwin.close(child.output) }
        errors.setCancelHandler { Darwin.close(child.error) }
        outputSource = output; errorSource = errors
        output.activate(); errors.activate()
    }
    deinit { _ = closeSynchronously() }

    func diagnostics() -> MCPProcessDiagnostics {
        state.lock(); defer { state.unlock() }
        return .init(stderrBytesDiscarded: stderrCount, exited: reaped, forcedTermination: forced)
    }
    func write(_ frame: Data, timeout: TimeInterval) async throws {
        guard frame.count <= 262_144 else { throw MCPClientError.limitExceeded }
        let cancellation = MCPWriteCancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await Task.detached(priority: .utility) {
                try self.writeSynchronously(frame, timeout: timeout, cancellation: cancellation)
            }.value
        }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
    }
    func close() async -> MCPProcessDiagnostics {
        await Task.detached(priority: .utility) { self.closeSynchronously() }.value
    }

    private func writeSynchronously(_ frame: Data, timeout: TimeInterval, cancellation: MCPWriteCancellation) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while !writer.try() {
            try cancellation.check()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw MCPClientError.timeout }
            _ = Darwin.poll(nil, 0, 10)
        }
        defer { writer.unlock() }
        try cancellation.check()
        state.lock(); let descriptor = input; let stopped = closed; state.unlock()
        guard !stopped, descriptor >= 0 else { throw MCPClientError.processExited }
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < frame.count {
                try cancellation.check()
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw MCPClientError.timeout }
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { throw MCPClientError.processExited }
                var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&item, 1, 10)
            }
        }
    }
    private func read(_ descriptor: Int32, stderr: Bool) {
        var storage = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &storage, storage.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        state.lock(); defer { state.unlock() }
        guard !closed else { return }
        if stderr {
            if count > 0 {
                stderrCount += count
                if stderrCount > 1_048_576 { endOutputLocked(MCPClientError.limitExceeded) }
            } else if count == 0 { errorSource?.cancel() }
            return
        }
        guard !outputEnded else { return }
        if count <= 0 {
            endOutputLocked(buffer.isEmpty && count == 0 ? nil : MCPClientError.invalidResponse)
            return
        }
        stdoutCount += count
        guard stdoutCount <= 16_777_216 else { endOutputLocked(MCPClientError.limitExceeded); return }
        buffer.append(contentsOf: storage.prefix(count))
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            guard !line.isEmpty, line.count <= 262_144 else { endOutputLocked(MCPClientError.invalidResponse); return }
            guard let continuation else { return }
            switch continuation.yield(line) {
            case .enqueued: break
            case .dropped: endOutputLocked(MCPClientError.limitExceeded); return
            case .terminated: endOutputLocked(nil); return
            @unknown default: endOutputLocked(MCPClientError.invalidResponse); return
            }
        }
        if buffer.count > 262_144 { endOutputLocked(MCPClientError.limitExceeded) }
    }
    private func endOutputLocked(_ error: Error?) {
        guard !outputEnded else { return }
        outputEnded = true; buffer.removeAll()
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil; outputSource?.cancel()
    }
    private func closeSynchronously() -> MCPProcessDiagnostics {
        writer.lock()
        state.lock()
        if closed { state.unlock(); writer.unlock(); return diagnostics() }
        closed = true
        let descriptor = input; input = -1
        continuation?.finish(); continuation = nil
        outputSource?.cancel(); errorSource?.cancel()
        state.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
        writer.unlock()
        // EOF优先；只有waitpid确认仍是未回收的自有child，才允许后续信号。
        if !waitForExit(milliseconds: 500) {
            _ = Darwin.kill(pid, SIGTERM)
            if !waitForExit(milliseconds: 1000) {
                state.lock(); forced = true; state.unlock()
                _ = Darwin.kill(pid, SIGKILL)
                _ = waitForExit(milliseconds: 1000)
            }
        }
        return diagnostics()
    }
    private func waitForExit(milliseconds: UInt64) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) {
                state.lock(); reaped = true; state.unlock(); return true
            }
            if result < 0 && errno != EINTR { return false }
            if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            _ = Darwin.poll(nil, 0, 10)
        }
    }

    private static func spawn(_ configuration: MCPStdioLaunchConfiguration) throws -> (pid: pid_t, input: Int32, output: Int32, error: Int32) {
        var descriptors = [Int32](repeating: -1, count: 6)
        defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
        for index in stride(from: 0, to: 6, by: 2) {
            var pair: [Int32] = [-1, -1]
            guard Darwin.pipe(&pair) == 0 else { throw MCPClientError.transport }
            descriptors[index] = pair[0]; descriptors[index + 1] = pair[1]
        }
        guard descriptors.allSatisfy({ $0 >= 3 }) else { throw MCPClientError.transport }
        for fd in [descriptors[1], descriptors[2], descriptors[4]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw MCPClientError.transport }
        }
        guard fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0 else { throw MCPClientError.transport }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw MCPClientError.transport }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw MCPClientError.transport }
        defer { posix_spawnattr_destroy(&attributes) }
        for (source, target) in [(descriptors[0], STDIN_FILENO), (descriptors[3], STDOUT_FILENO), (descriptors[5], STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw MCPClientError.transport }
        }
        for fd in descriptors {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw MCPClientError.transport }
        }
        guard posix_spawn_file_actions_addchdir_np(&actions, configuration.workingDirectory) == 0 else { throw MCPClientError.transport }
        var mask = sigset_t(), defaults = sigset_t(); sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0 else { throw MCPClientError.transport }
        let argumentValues: [String] = [configuration.executable] + configuration.arguments
        let environmentValues: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8", "TMPDIR=/tmp"]
        var argv: [UnsafeMutablePointer<CChar>?] = argumentValues.map { strdup($0) }
        var env: [UnsafeMutablePointer<CChar>?] = environmentValues.map { strdup($0) }
        defer { for pointer in argv + env { if let pointer { free(pointer) } } }
        guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else { throw MCPClientError.transport }
        argv.append(nil); env.append(nil)
        var child: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { arguments in
            env.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&child, configuration.executable, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
            }
        }
        guard result == 0 else { throw MCPClientError.transport }
        let input = descriptors[1], output = descriptors[2], error = descriptors[4]
        descriptors[1] = -1; descriptors[2] = -1; descriptors[4] = -1
        return (child, input, output, error)
    }
}
