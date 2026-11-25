import Foundation

public enum DesktopWorkspaceReceiptPhase: String, Codable, Sendable { case launch, focus, layout }

/// 在任何原生请求前保存完整有序条目清单；缺少child intent时不依赖已编辑的定义猜测。
public struct DesktopWorkspaceRunContext: Codable, Sendable, Equatable {
    public let workspaceID: UUID
    public let revision: Int
    public let entryIDs: [UUID]
    public init(workspaceID: UUID, revision: Int, entryIDs: [UUID]) throws {
        guard revision > 0, (1...8).contains(entryIDs.count), Set(entryIDs).count == entryIDs.count else { throw InvocationStoreError.invalidMetadata }
        self.workspaceID = workspaceID; self.revision = revision; self.entryIDs = entryIDs
    }
    private enum CodingKeys: String, CodingKey { case workspaceID, revision, entryIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(workspaceID: c.decode(UUID.self, forKey: .workspaceID), revision: c.decode(Int.self, forKey: .revision), entryIDs: c.decode([UUID].self, forKey: .entryIDs))
    }
}

/// 重启后仍能核对条目顺序和阶段；不存窗口对象、PID、标题、frame或应用路径。
public struct DesktopWorkspaceReceiptContext: Codable, Sendable, Equatable {
    public static let commandPrefix = "keydock.desktop-workspace-run."
    public let parentID: UUID
    public let entryID: UUID
    public let entryIndex: Int
    public let phase: DesktopWorkspaceReceiptPhase
    public var commandID: String { Self.commandPrefix + parentID.uuidString }
    public init(parentID: UUID, entryID: UUID, entryIndex: Int, phase: DesktopWorkspaceReceiptPhase) throws {
        guard (0..<8).contains(entryIndex) else { throw InvocationStoreError.invalidMetadata }
        self.parentID = parentID; self.entryID = entryID; self.entryIndex = entryIndex; self.phase = phase
    }
    private enum CodingKeys: String, CodingKey { case parentID, entryID, entryIndex, phase }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(parentID: c.decode(UUID.self, forKey: .parentID), entryID: c.decode(UUID.self, forKey: .entryID),
                      entryIndex: c.decode(Int.self, forKey: .entryIndex), phase: c.decode(DesktopWorkspaceReceiptPhase.self, forKey: .phase))
    }
}
