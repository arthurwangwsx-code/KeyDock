import Foundation

public enum DesktopWorkspaceValidationError: Error, Equatable { case invalidDefinition, invalidArchive }
public enum DesktopWorkspaceWindowSelector: String, Codable, Sendable { case focusedWindowAtInvocation }
public enum DesktopWorkspaceDisplayPolicy: String, Codable, CaseIterable, Sendable { case invocationDisplay, windowDisplay, mainDisplay }
public enum DesktopWorkspaceMissingApplicationPolicy: String, Codable, CaseIterable, Sendable { case requireRunning, launchInBackground }

/// 这里只保存定位引用与明确策略。目录对象、进程及窗口身份必须在每次运行时冻结。
public struct DesktopWorkspaceEntry: Identifiable, Codable, Sendable, Equatable {
    public static let allowedLayouts: [WindowLayout] = [.leftHalf,.rightHalf,.topHalf,.bottomHalf,.topLeft,.topRight,.bottomLeft,.bottomRight,.maximize,.center]
    public let id: UUID
    public let applicationID: String
    public let selector: DesktopWorkspaceWindowSelector
    public let layout: WindowLayout
    public let display: DesktopWorkspaceDisplayPolicy
    public let missingApplication: DesktopWorkspaceMissingApplicationPolicy
    public init(id: UUID = UUID(), applicationID: String, selector: DesktopWorkspaceWindowSelector = .focusedWindowAtInvocation,
                layout: WindowLayout = .maximize, display: DesktopWorkspaceDisplayPolicy = .windowDisplay,
                missingApplication: DesktopWorkspaceMissingApplicationPolicy = .requireRunning) throws {
        guard Self.validApplicationID(applicationID), Self.allowedLayouts.contains(layout) else { throw DesktopWorkspaceValidationError.invalidDefinition }
        self.id = id; self.applicationID = applicationID; self.selector = selector
        self.layout = layout; self.display = display; self.missingApplication = missingApplication
    }
    public static func validApplicationID(_ value: String) -> Bool {
        guard value.hasPrefix("app./"), value.utf8.count <= 4_096, !hasControl(value), !value.contains(where: \.isNewline) else { return false }
        let path = String(value.dropFirst(4)), components = path.split(separator: "/", omittingEmptySubsequences: false)
        // 仅做词法检查，不解析磁盘／符号链接，也不改变路径的大小写或Unicode字节。
        return components.first == "" && components.count > 1
            && components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && components.last?.lowercased().hasSuffix(".app") == true
    }
    static func hasControl(_ value: String) -> Bool { value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } }
    private enum CodingKeys: String, CodingKey { case id, applicationID, selector, layout, display, missingApplication }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), applicationID: c.decode(String.self, forKey: .applicationID),
            selector: c.decode(DesktopWorkspaceWindowSelector.self, forKey: .selector), layout: c.decode(WindowLayout.self, forKey: .layout),
            display: c.decode(DesktopWorkspaceDisplayPolicy.self, forKey: .display), missingApplication: c.decode(DesktopWorkspaceMissingApplicationPolicy.self, forKey: .missingApplication))
    }
}

public struct SavedDesktopWorkspace: Identifiable, Codable, Sendable, Equatable {
    public static let maximumEntries = 8
    public let id: UUID
    public let revision: Int
    public let name: String
    public let entries: [DesktopWorkspaceEntry]
    public var commandID: String { "desktop-workspace." + id.uuidString }
    public init(id: UUID = UUID(), revision: Int = 1, name: String, entries: [DesktopWorkspaceEntry]) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision > 0, !title.isEmpty, title.utf8.count <= 160, !DesktopWorkspaceEntry.hasControl(title), !title.contains(where: \.isNewline),
              (1...Self.maximumEntries).contains(entries.count), Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.applicationID)).count == entries.count else { throw DesktopWorkspaceValidationError.invalidDefinition }
        self.id = id; self.revision = revision; self.name = title; self.entries = entries
    }
    private enum CodingKeys: String, CodingKey { case id, revision, name, entries }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), revision: c.decode(Int.self, forKey: .revision),
            name: c.decode(String.self, forKey: .name), entries: c.decode([DesktopWorkspaceEntry].self, forKey: .entries))
    }
}

public struct DesktopWorkspaceArchive: Codable, Sendable, Equatable {
    public static let maximumWorkspaces = 32
    public static let maximumBytes = 1_048_576
    public let schemaVersion: Int
    public let workspaces: [SavedDesktopWorkspace]
    public init(workspaces: [SavedDesktopWorkspace]) throws {
        guard workspaces.count <= Self.maximumWorkspaces, Set(workspaces.map(\.id)).count == workspaces.count else { throw DesktopWorkspaceValidationError.invalidArchive }
        schemaVersion = 1; self.workspaces = workspaces
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw DesktopWorkspaceValidationError.invalidArchive }
        return bytes
    }
    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw DesktopWorkspaceValidationError.invalidArchive }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, workspaces }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw DesktopWorkspaceValidationError.invalidArchive }
        try self.init(workspaces: c.decode([SavedDesktopWorkspace].self, forKey: .workspaces))
    }
}
