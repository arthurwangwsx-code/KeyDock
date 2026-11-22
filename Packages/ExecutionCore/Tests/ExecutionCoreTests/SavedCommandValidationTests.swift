import Foundation
import Testing
import ExecutionCore

@Suite struct SavedCommandValidationTests {
    @Test func invalidArgumentsCannotBypassValidationByChoosingTerminalMode() async throws {
        var cases: [SavedCommand] = []
        let base = SavedCommand(name: "Synthetic validation", executable: "/usr/bin/printf", workingDirectory: "/tmp")
        var value = base; value.executable = "printf"; cases.append(value)
        value = base; value.workingDirectory = "relative"; cases.append(value)
        value = base; value.arguments = ["invalid\0argument"]; cases.append(value)
        value = base; value.environment = ["INVALID=NAME": "synthetic"]; cases.append(value)
        value = base; value.environment = ["KEYDOCK_SYNTHETIC": "invalid\0value"]; cases.append(value)
        value = base; value.timeout = .infinity; cases.append(value)
        value = base; value.name = " \n "; cases.append(value)
        let runner = ProcessRunner()
        defer { withExtendedLifetime(runner) {} }
        for invalid in cases {
            let events = await runner.run(invalid, id: UUID())
            var started = false, result: ProcessResult?
            for await event in events {
                if case .started = event { started = true }
                if case .finished(let value) = event { result = value }
            }
            #expect(!started && result?.message == "process.invalidConfiguration")
            var interactive = invalid; interactive.interactive = true
            #expect(throws: SavedCommandValidationError.self) {
                try TerminalLaunchScript.make(command: interactive, launchFile: URL(fileURLWithPath: "/tmp/keydock-synthetic.command"))
            }
        }
    }

    @Test func generatedScriptPreservesLiteralArgumentsEnvironmentAndDirectoryWithoutShellExpansion() async throws {
        // 只通过一次性Runner运行合成脚本文本，不打开Terminal、不代替真实终端交接验收。
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Script-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic ' launch.command")
        let marker = directory.appendingPathComponent("must-not-be-created")
        let payload = "literal ' \" $HOME $(touch " + marker.path + ")"
        let arguments = ["-c", "printf '%s\\n' \"$KEYDOCK_TEXT\" \"$@\"; /bin/pwd", "fixture", payload, "line\nbreak", "`touch " + marker.path + "`"]
        let command = SavedCommand(name: "Synthetic terminal script", executable: "/bin/sh", arguments: arguments, workingDirectory: directory.path,
                                   environment: ["KEYDOCK_TEXT": payload, "-S": "/usr/bin/touch " + marker.path], timeout: 5, interactive: true, shellMode: true)
        let script = try TerminalLaunchScript.make(command: command, launchFile: file)
        try Data(script.utf8).write(to: file)
        let runner = ProcessRunner()
        defer { withExtendedLifetime(runner) {} }
        let events = await runner.run(.init(name: "Synthetic script evaluation", executable: "/bin/zsh", arguments: [file.path], workingDirectory: directory.path, timeout: 5), id: UUID())
        var output = "", result: ProcessResult?
        for await event in events {
            if case .output(let text, _) = event { output += text }
            if case .finished(let value) = event { result = value }
        }
        #expect(result?.state == .succeeded && result?.exitCode == 0)
        // /tmp在macOS上可能解析成/private/tmp；标准化后只比较当前合成目录。
        let expectedDirectory = directory.resolvingSymlinksInPath().path
        let expected = [payload, payload, "line\nbreak", "`touch " + marker.path + "`", expectedDirectory].joined(separator: "\n") + "\n"
        #expect(output == expected)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
