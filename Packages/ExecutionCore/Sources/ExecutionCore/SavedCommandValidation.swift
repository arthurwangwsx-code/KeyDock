import Foundation

public enum SavedCommandValidationError: Error, Equatable, Sendable {
    case invalidName, invalidExecutable, invalidDirectory, invalidArguments
    case invalidEnvironment, invalidTimeout, invalidLaunchFile, requiresInteractiveMode
}

extension SavedCommand {
    /// Process 与终端交接共用校验，避免切换执行模式扩大可接受输入。
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SavedCommandValidationError.invalidName }
        guard executable.hasPrefix("/"), !executable.utf8.contains(0) else { throw SavedCommandValidationError.invalidExecutable }
        guard workingDirectory.hasPrefix("/"), !workingDirectory.utf8.contains(0) else { throw SavedCommandValidationError.invalidDirectory }
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else { throw SavedCommandValidationError.invalidArguments }
        guard environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.utf8.contains(0) && !value.utf8.contains(0)
        }) else { throw SavedCommandValidationError.invalidEnvironment }
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw SavedCommandValidationError.invalidTimeout }
    }
}

/// 仅创建用户已选终端模式的脚本文本；本模块不打开应用或执行脚本。
public enum TerminalLaunchScript {
    public static func make(command: SavedCommand, launchFile: URL) throws -> String {
        try command.validate()
        guard command.interactive else { throw SavedCommandValidationError.requiresInteractiveMode }
        guard launchFile.isFileURL, launchFile.path.hasPrefix("/"), !launchFile.path.utf8.contains(0) else { throw SavedCommandValidationError.invalidLaunchFile }
        let executable = ([command.executable] + command.arguments).map(quote).joined(separator: " ")
        let environment = command.environment.sorted { $0.key < $1.key }.map { quote($0.key + "=" + $0.value) }.joined(separator: " ")
        // -- 终止 env 的选项解析，环境变量名称即使以 - 开头也不能成为工具选项。
        return "#!/bin/zsh\n/bin/rm -f -- \"$0\"\ncd -- \(quote(command.workingDirectory)) || exit 1\nexec /usr/bin/env -- \(environment) \(executable)\n"
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
