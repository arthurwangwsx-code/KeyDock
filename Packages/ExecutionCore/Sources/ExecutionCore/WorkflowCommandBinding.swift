import Foundation

public enum WorkflowCommandBinding {
    /// 只有用户在已保存argv中明确放置的完整占位参数可替换，不改可执行文件、目录或环境。
    public static func apply(_ input: String, to command: SavedCommand) throws -> SavedCommand {
        try command.validate()
        guard !command.interactive, input.utf8.count <= 131_072 else { throw SavedCommandValidationError.invalidArguments }
        guard !command.shellMode || !command.arguments.contains("{{input}}") else { throw SavedCommandValidationError.invalidArguments }
        var result = command
        result.arguments = command.arguments.map { $0 == "{{input}}" ? input : $0 }
        try result.validate()
        guard result.arguments.reduce(0, { $0+$1.utf8.count }) <= 196_608 else { throw SavedCommandValidationError.invalidArguments }
        return result
    }
}
