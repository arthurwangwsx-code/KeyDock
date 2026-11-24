import Foundation

public enum WindowCommand: String, Codable, CaseIterable, Sendable {
    case focusNext, focusPrevious, minimize
    public var titleKey: String {
        switch self {
        case .focusNext: "Current app: Next window"
        case .focusPrevious: "Current app: Previous window"
        case .minimize: "Current window: Minimize"
        }
    }
}

public enum ApplicationBehavior: String, Codable, CaseIterable, Sendable {
    case launchOrActivate, toggleVisibility, hide, show, showAllWindows, requestQuit
    public var titleKey: String {
        switch self {
        case .launchOrActivate: "Launch or activate"
        case .toggleVisibility: "Hide when frontmost, otherwise show"
        case .hide: "Hide application"
        case .show: "Show application"
        case .showAllWindows: "Show all application windows"
        case .requestQuit: "Request normal quit"
        }
    }
    public var mayLaunch: Bool { self == .launchOrActivate || self == .toggleVisibility }
}

public enum DesktopActionValidationError: Error { case invalidDefinition }

/// 配置只能选择已注册行为，不能携带effects、进程PID、AX对象或授权。
public struct SavedApplicationAction: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let version: Int
    public let name: String
    public let applicationID: String
    public let behavior: ApplicationBehavior
    public init(id: UUID = UUID(), version: Int = 1, name: String, applicationID: String, behavior: ApplicationBehavior) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == 1, !title.isEmpty, title.utf8.count <= 160, !title.contains("\0"),
              !title.contains(where: { $0.isNewline }), applicationID.hasPrefix("app./"),
              applicationID.utf8.count <= 4_096, !applicationID.contains("\0"),
              !applicationID.contains(where: { $0.isNewline }),
              URL(fileURLWithPath: String(applicationID.dropFirst(4))).pathExtension.lowercased() == "app" else {
            throw DesktopActionValidationError.invalidDefinition
        }
        self.id = id; self.version = version; self.name = title; self.applicationID = applicationID; self.behavior = behavior
    }
    private enum CodingKeys: String, CodingKey { case id, version, name, applicationID, behavior }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), version: c.decode(Int.self, forKey: .version),
                      name: c.decode(String.self, forKey: .name), applicationID: c.decode(String.self, forKey: .applicationID),
                      behavior: c.decode(ApplicationBehavior.self, forKey: .behavior))
    }
}

/// 系统接口接受请求与目标状态确认分开；unknown不能被解释为无副作用失败。
public enum DesktopControlOutcome: Sendable, Equatable {
    case confirmed, noOp, requestSubmitted, declined, outcomeUnknown, cancelledBeforeDispatch
}
