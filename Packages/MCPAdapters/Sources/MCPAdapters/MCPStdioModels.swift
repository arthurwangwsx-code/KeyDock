import Foundation

/// 仅启动用户已明确配置的绝对路径命令，不经过shell，不继承整套宿主环境。
public struct MCPStdioLaunchConfiguration: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let startupTimeoutSeconds: TimeInterval
    public init(executable: String, arguments: [String] = [], workingDirectory: String, startupTimeoutSeconds: TimeInterval = 30) {
        self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory
        self.startupTimeoutSeconds = startupTimeoutSeconds
    }
    private enum CodingKeys: String, CodingKey { case executable, arguments, workingDirectory, startupTimeoutSeconds }
    public init(from decoder:any Decoder) throws {
        let fields = try decoder.container(keyedBy:CodingKeys.self)
        executable = try fields.decode(String.self,forKey:.executable)
        arguments = try fields.decode([String].self,forKey:.arguments)
        workingDirectory = try fields.decode(String.self,forKey:.workingDirectory)
        startupTimeoutSeconds = try fields.decodeIfPresent(TimeInterval.self,forKey:.startupTimeoutSeconds) ?? 30
    }
    public func validate() throws {
        try validateStructure()
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw MCPClientError.invalidConfiguration }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &directory), directory.boolValue else {
            throw MCPClientError.invalidConfiguration
        }
    }
    /// 准备审阅只校验值，不触及可执行文件、目录或OS权限。
    public func validateStructure() throws {
        guard executable.hasPrefix("/"), executable.utf8.count <= 4096, !executable.contains("\0"),
              workingDirectory.hasPrefix("/"), workingDirectory.utf8.count <= 4096, !workingDirectory.contains("\0"),
              arguments.count <= 128, arguments.allSatisfy({ !$0.contains("\0") }),
              startupTimeoutSeconds.isFinite, (1...120).contains(startupTimeoutSeconds),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else { throw MCPClientError.invalidConfiguration }
    }
}

public struct MCPProcessDiagnostics: Equatable, Sendable {
    public let stderrBytesDiscarded: Int
    public let exited: Bool
    public let forcedTermination: Bool
}

/// 现代协议的名称头安全编码，包含sentinel字面值去歧义。
public enum MCPHeaderValue {
    public static func encode(_ value: String) -> String {
        let ascii = value.utf8.allSatisfy { (0x20...0x7e).contains($0) || $0 == 9 }
        let boundaryWhitespace = value.first?.isWhitespace == true || value.last?.isWhitespace == true
        let sentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        if ascii && !boundaryWhitespace && !sentinel { return value }
        return "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }
}
