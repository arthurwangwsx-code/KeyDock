import Foundation
import Darwin
import Testing
import AICore

private enum FixtureError: Error { case missingScript, startupFailed, timedOut }

/// 每个测试使用独立的 loopback 子进程，结束时终止；不读取 Keychain 或调用云服务。
private final class SSEFixture {
    let baseURL: URL
    private let lock = NSLock()
    private var childPID: pid_t = 0
    private var outputFD: Int32 = -1

    init() throws {
        let script = try Self.locateScript()
        let child = try Self.spawn(script)
        do {
            let port = try Self.readPort(child.output)
            guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw FixtureError.startupFailed }
            baseURL = url; childPID = child.pid; outputFD = child.output
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
    func provider(path: String) -> ChatCompletionsProvider {
        let configuration = AIProviderConfiguration(endpoint: baseURL.appendingPathComponent(path), model: "synthetic-fixture-model", allowsLocalHTTP: true, timeout: 5)
        return ChatCompletionsProvider(configuration: configuration, apiKey: "synthetic-fixture-key")
    }
    private static func locateScript() throws -> URL {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let script = folder.appendingPathComponent("Tools/Fixtures/sse_server.py")
            if FileManager.default.fileExists(atPath: script.path) { return script }
            let parent = folder.deletingLastPathComponent()
            if parent == folder { break }
            folder = parent
        }
        throw FixtureError.missingScript
    }
    private static func readPort(_ descriptor: Int32) throws -> Int {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        var bytes = Data()
        while bytes.count < 16 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw FixtureError.startupFailed }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let milliseconds = Int32(min((deadline - now) / 1_000_000, 5000))
            let ready = Darwin.poll(&item, 1, milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw FixtureError.startupFailed }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw FixtureError.startupFailed }
            if byte == 10 {
                guard let value = Int(String(decoding: bytes, as: UTF8.self)), (1...65535).contains(value) else { throw FixtureError.startupFailed }
                return value
            }
            bytes.append(byte)
        }
        throw FixtureError.startupFailed
    }
    private static func spawn(_ script: URL) throws -> (pid: pid_t, output: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw FixtureError.startupFailed }
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
        let argumentStrings: [String] = ["env", "python3", "-I", "-u", script.path]
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
                posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(result)
        Darwin.close(descriptors[1]); descriptors[1] = -1
        let output = descriptors[0]; descriptors[0] = -1
        return (pid, output)
    }
    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw FixtureError.startupFailed }
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

private func within<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: duration); throw FixtureError.timedOut }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func syntheticRequest() -> AIRequest {
    .init(messages: [.init(role: "user", content: "Synthetic network integration input")])
}

@Suite(.serialized) struct HTTPIntegrationTests {
    @Test func fixtureCleanupIsBoundedAndIdempotent() throws {
        let server = try SSEFixture()
        let start = ContinuousClock.now
        server.stop()
        server.stop()
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func liveURLSessionParsesNetworkUTF8FragmentsAndUsage() async throws {
        let server = try SSEFixture(); defer { server.stop() }
        let provider = server.provider(path: "stream")
        let events = try await within(.seconds(5)) { () -> [AIEvent] in
            var events: [AIEvent] = []
            for try await event in provider.stream(syntheticRequest()) { events.append(event) }
            return events
        }
        let text = events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        let usage = events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
        let completed = events.filter { if case .completed = $0 { true } else { false } }.count
        #expect(text == "你好，网络 🌍")
        #expect(usage.count == 1)
        #expect(usage.first?.inputTokens == 12 && usage.first?.outputTokens == 5)
        #expect(usage.first?.counting == .cumulative)
        #expect(completed == 1)
    }

    @Test(arguments: [401, 429]) func liveHTTPStatusDoesNotExposeResponseBody(status: Int) async throws {
        let server = try SSEFixture(); defer { server.stop() }
        let provider = server.provider(path: "error/\(status)")
        do {
            for try await _ in provider.stream(syntheticRequest()) {}
            Issue.record("Expected a typed HTTP error")
        } catch {
            #expect(error as? AIProviderError == .httpStatus(status))
            #expect(!String(describing: error).contains("synthetic-private-response-body"))
            #expect(!String(describing: error).contains("synthetic-fixture-key"))
        }
    }

    @Test func liveRedirectIsRejectedWithoutForwardingCredentials() async throws {
        let server = try SSEFixture(); defer { server.stop() }
        let provider = server.provider(path: "redirect")
        await #expect(throws: AIProviderError.httpStatus(307)) {
            for try await _ in provider.stream(syntheticRequest()) {}
        }
        let (data, response) = try await URLSession.shared.data(from: server.baseURL.appendingPathComponent("stats"))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let stats = try JSONDecoder().decode([String: Int].self, from: data)
        #expect(stats["redirect_hits"] == 0)
        #expect(stats["redirect_authorization_seen"] == 0)
    }

    @Test func liveMissingDoneFailsInsteadOfReportingSuccess() async throws {
        let server = try SSEFixture(); defer { server.stop() }
        let provider = server.provider(path: "truncated")
        var completed = 0, text = ""
        do {
            for try await event in provider.stream(syntheticRequest()) {
                if case .completed = event { completed += 1 }
                if case .text(let delta) = event { text += delta }
            }
            Issue.record("Expected truncated stream error")
        } catch { #expect(error as? AIProviderError == .truncatedStream) }
        #expect(text == "Synthetic partial")
        #expect(completed == 0)
    }

    @Test func liveCancellationClosesTheHTTPStreamPromptly() async throws {
        let server = try SSEFixture(); defer { server.stop() }
        let provider = server.provider(path: "slow")
        let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            for try await event in provider.stream(syntheticRequest()) {
                try Task.checkCancellation()
                if case .text = event { signal.yield(()) }
            }
            // AsyncStream 的取消可表现为 nil，不能把正常结束当成请求成功。
            try Task.checkCancellation()
        }
        defer { worker.cancel(); signal.finish() }
        let observed = try await within(.seconds(3)) {
            for await _ in started { return true }
            return false
        }
        try #require(observed)
        let clock = ContinuousClock(), start = ContinuousClock.now
        worker.cancel()
        let cancelled = try await within(.seconds(2)) {
            do { try await worker.value; return false }
            catch { return error is CancellationError || (error as? URLError)?.code == .cancelled }
        }
        #expect(cancelled)
        #expect(clock.now - start < .seconds(2))
        let statsURL = server.baseURL.appendingPathComponent("stats")
        let networkClosed = try await within(.seconds(3)) {
            while true {
                let (data, _) = try await URLSession.shared.data(from: statsURL)
                let stats = try JSONDecoder().decode([String: Int].self, from: data)
                if (stats["slow_closed"] ?? 0) > 0 && stats["slow_open"] == 0 { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(networkClosed)
    }
}
