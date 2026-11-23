import Foundation
import Darwin
import Testing
import MacAdapters
@testable import WorkbenchFeature

enum StoreHTTPError: Error { case missingScript, startupFailed, timedOut }

/// 每个测试使用独立的 loopback 子进程，结束时终止；不读取 Keychain 或调用云服务。
final class StoreSSEServer {
    let baseURL: URL
    private let lock = NSLock()
    private var childPID: pid_t = 0
    private var outputFD: Int32 = -1

    init() throws {
        let script = try Self.locateScript()
        let child = try Self.spawn(script)
        do {
            let port = try Self.readPort(child.output)
            guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw StoreHTTPError.startupFailed }
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
    func endpoint(_ path: String) -> String { baseURL.appendingPathComponent(path).absoluteString }
    @MainActor func stats() async throws -> [String: Int] {
        var request = URLRequest(url: baseURL.appendingPathComponent("stats"), timeoutInterval: 2)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreHTTPError.startupFailed }
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
    @MainActor func releaseProposals() async throws {
        let request = URLRequest(url: baseURL.appendingPathComponent("release-proposal"), timeoutInterval: 2)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreHTTPError.startupFailed }
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
        throw StoreHTTPError.missingScript
    }
    private static func readPort(_ descriptor: Int32) throws -> Int {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        var bytes = Data()
        while bytes.count < 16 {
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
                guard let value = Int(String(decoding: bytes, as: UTF8.self)), (1...65535).contains(value) else { throw StoreHTTPError.startupFailed }
                return value
            }
            bytes.append(byte)
        }
        throw StoreHTTPError.startupFailed
    }
    private static func spawn(_ script: URL) throws -> (pid: pid_t, output: Int32) {
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


/// 只观察主线程 Store 与 loopback 统计；超时抛出，不形成无界等待。
@MainActor func storeEventually(_ duration: Duration = .seconds(5), _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + duration
    repeat {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    throw StoreHTTPError.timedOut
}

@MainActor final class StoreHTTPFixture {
    let directory: URL
    let server: StoreSSEServer
    let store: WorkbenchModel
    let action: AIActionPreset
    private let languageKey: String
    private let previousLanguage: Any?

    init(path: String, clipboardWriter: @escaping @MainActor (String) -> Void = { _ in }, clipboardChangeCount: @escaping @MainActor () -> Int = { 0 }) throws {
        server = try StoreSSEServer()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-StoreHTTP-" + UUID().uuidString, isDirectory: true)
        languageKey = (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) ? "KeyDock.Smoke.Language" : "KeyDock.Language"
        previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        var preset = AIActionPreset(name: "Synthetic network action", prompt: "Process only the following synthetic input.")
        preset.input = .manual; preset.output = .display; action = preset
        var configuration = AppConfiguration()
        configuration.endpoint = server.endpoint(path); configuration.model = "synthetic-store-model"
        configuration.localHTTP = true; configuration.aiActions = [preset]
        // 保持既有语言偏好，测试不通过标签判断任务身份。
        configuration.language = previousLanguage as? String ?? "system"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"))
            store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false, clipboardWriter: clipboardWriter, clipboardChangeCount: clipboardChangeCount, applicationCatalog: ApplicationCatalog(roots: []))
        } catch {
            server.stop(); try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    func drain(_ id: UUID) async throws {
        try await storeEventually { self.store.taskHandles[id] == nil }
    }
    func usage(_ id: UUID) throws -> StoreUsageReceipt {
        try JSONDecoder().decode(StoreUsageReceipt.self, from: usageData(id))
    }
    func usageData(_ id: UUID) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("usage/" + id.uuidString + ".json"))
    }
    func assertNoCommandEffects(marker: URL? = nil) throws {
        if let marker { #expect(!FileManager.default.fileExists(atPath: marker.path)) }
        #expect(store.configuration.savedCommands.isEmpty)
        // Store 初始化会写空索引；检查索引内无调用，而不是误把索引文件当成执行回执。
        struct Identity: Decodable { let id: UUID }
        struct Index: Decodable { let version: Int; let receipts: [Identity] }
        let folder = directory.appendingPathComponent("invocations")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == ["invocations.json"])
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("invocations.json")))
        #expect(index.version == 1 && index.receipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("terminal-launches").path))
    }
    func cleanup() async {
        store.shutdown()
        for id in Array(store.taskHandles.keys) { store.cancelTask(id) }
        server.stop()
        var drained = false
        do { try await storeEventually { self.store.taskHandles.isEmpty }; drained = true }
        catch { Issue.record("Synthetic Store HTTP tasks did not drain within cleanup deadline") }
        if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: languageKey) }
        else { UserDefaults.standard.removeObject(forKey: languageKey) }
        // 失败时留下合成目录供排查，避免与尚未收口的写入竞争。
        if drained { try? FileManager.default.removeItem(at: directory) }
    }
}

struct StoreUsageReceipt: Decodable {
    struct Observation: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let attemptID: UUID
        let responseID: String?
        let counting: String
    }
    let runID: UUID
    let endpointHost: String
    let model: String
    let purpose: String
    let observations: [Observation]
    let unknownAttempts: Set<UUID>
    let hasUnknownUsage: Bool
    let outcome: String
    let costBasis: String
}

@MainActor func withStoreHTTPFixture(path: String, clipboardWriter: @escaping @MainActor (String) -> Void = { _ in }, clipboardChangeCount: @escaping @MainActor () -> Int = { 0 }, _ operation: (StoreHTTPFixture) async throws -> Void) async throws {
    let fixture = try StoreHTTPFixture(path: path, clipboardWriter: clipboardWriter, clipboardChangeCount: clipboardChangeCount)
    do { try await operation(fixture); await fixture.cleanup() }
    catch { await fixture.cleanup(); throw error }
}
