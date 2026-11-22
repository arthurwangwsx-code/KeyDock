import Darwin
import Foundation
import Testing
@testable import ExecutionCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProcessRunnerTests {
    private struct Capture {
        var events: [ProcessEvent] = []
        var stdout = ""
        var stderr = ""
        var result: ProcessResult?
    }

    private func collect(_ command: SavedCommand, runner: ProcessRunner = ProcessRunner()) async -> Capture {
        var capture = Capture()
        for await event in await runner.run(command, id: UUID()) {
            capture.events.append(event)
            switch event {
            case let .output(value, isError):
                if isError { capture.stderr += value } else { capture.stdout += value }
            case let .finished(result): capture.result = result
            case .started: break
            }
        }
        return capture
    }

    @Test func argvDoesNotExpandShellSyntaxOrLoseUnicode() async throws {
        let literal = "$HOME; $(echo INJECTION) * 'quoted' \"double\" 中文🙂"
        let capture = await collect(.init(name: "literal", executable: "/usr/bin/printf", arguments: ["%s", literal]))
        #expect(capture.stdout == literal)
        #expect(capture.result?.state == .succeeded)
        #expect(capture.result?.exitCode == 0)
    }

    @Test func bothPipesDrainUnderBackpressureAndOutputIsBounded() async throws {
        let capture = await collect(
            .init(name: "pipe fixture", executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 6000 ]; do printf 'stdout-abcdefghijklmnopqrstuvwxyz0123456789\\n'; printf 'stderr-abcdefghijklmnopqrstuvwxyz0123456789\\n' >&2; i=$((i+1)); done"], shellMode: true),
            runner: ProcessRunner(outputLimitBytes: 32_768)
        )
        #expect(capture.result?.state == .succeeded)
        #expect(capture.stdout.contains("stdout-"))
        #expect(capture.stderr.contains("stderr-"))
        #expect(capture.stderr.contains("process.outputTruncated"))
        #expect(capture.stdout.utf8.count + capture.stderr.utf8.count < 33_000)
        #expect(capture.events.filter { if case .finished = $0 { true } else { false } }.count == 1)
    }

    @Test func timeoutTerminatesSleepingCommand() async throws {
        let started = ContinuousClock.now
        let capture = await collect(.init(name: "timeout fixture", executable: "/bin/sleep", arguments: ["30"], timeout: 0.15))
        #expect(capture.result?.state == .timedOut)
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func explicitCancelTerminatesDescendantProcessGroup() async throws {
        let runner = ProcessRunner(), id = UUID()
        let command = SavedCommand(name: "cancel fixture", executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30 & printf '%s\\n' $!; wait"], shellMode: true)
        var descendant: Int32?, final: ProcessResult?
        for await event in await runner.run(command, id: id) {
            if case let .output(text, _) = event,
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), descendant == nil {
                descendant = pid
                await runner.cancel(id)
            }
            if case let .finished(result) = event { final = result }
        }
        #expect(final?.state == .cancelled)
        let childPID = try #require(descendant)
        try await waitForExit(childPID)
    }

    private actor PIDProbe {
        var pid: Int32?
        func set(_ value: Int32) { pid = value }
    }

    @Test func cancellingStreamConsumerStopsOwnedProcess() async throws {
        let runner = ProcessRunner(), probe = PIDProbe()
        let consumer = Task {
            for await event in await runner.run(.init(name: "consumer fixture", executable: "/bin/sleep", arguments: ["30"]), id: UUID()) {
                if case let .started(pid) = event { await probe.set(pid) }
            }
        }
        for _ in 0..<100 {
            if await probe.pid != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(await probe.pid)
        consumer.cancel()
        await consumer.value
        try await waitForExit(pid)
    }

    @Test func directoryAndExplicitEnvironmentReachChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Cwd-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = await collect(.init(name: "env fixture", executable: "/bin/sh", arguments: ["-c", "printf '%s|' \"$KEYDOCK_SYNTHETIC\"; /bin/pwd"], workingDirectory: directory.path, environment: ["KEYDOCK_SYNTHETIC": "value with space"], shellMode: true))
        #expect(capture.result?.state == .succeeded)
        let resolved = try #require(realpath(directory.path, nil))
        defer { free(resolved) }
        #expect(capture.stdout == "value with space|\(String(cString: resolved))\n")
    }

    @Test func invalidConfigurationNeverStartsProcess() async throws {
        let capture = await collect(.init(name: "invalid fixture", executable: "/usr/bin/printf", arguments: ["bad\0argument"]))
        #expect(capture.result?.state == .failed)
        #expect(!capture.events.contains { if case .started = $0 { true } else { false } })
    }

    private func waitForExit(_ pid: Int32) async throws {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Owned process remained after cancellation: \(pid)")
    }
}

@Suite(.serialized)
struct InvocationStoreTests {
    @Test func restartMarksUnfinishedInvocationUnknownAndFencesLateSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try InvocationStore(directory: directory), id = UUID()
        try await original.begin(id: id, name: "Synthetic task", commandID: "keydock.command.synthetic", commandVersion: 1, configurationFingerprint: "synthetic-hash", caller: "shortcut")
        let recovered = try InvocationStore(directory: directory)
        let before = await recovered.list()
        #expect(before.first?.state == .interrupted)
        #expect(before.first?.commandID == "keydock.command.synthetic")
        #expect(before.first?.configurationFingerprint == "synthetic-hash")
        #expect(before.first?.caller == "shortcut")
        #expect(before.first?.exitCode == nil)
        #expect(before.first?.message == "process.interrupted.unknown")
        try await recovered.finish(id: id, result: .init(state: .succeeded, exitCode: 0))
        let after = await recovered.list()
        #expect(after.first?.state == .interrupted)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("invocations.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func corruptReceiptIsReportedRatherThanOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("invocations.json")
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: file)
        #expect(throws: (any Error).self) { _ = try InvocationStore(directory: directory) }
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
