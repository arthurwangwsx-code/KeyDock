import Foundation
import CommandCore

public typealias DesktopWorkspaceStoreError = ArchiveStoreError
public typealias DesktopWorkspaceStoreFaultStage = ArchiveStoreFaultStage

@MainActor public final class DesktopWorkspaceStore {
    private let storage: PrivateArchiveStore<[SavedDesktopWorkspace]>
    public var workspaces: [SavedDesktopWorkspace] { storage.value }
    public var writable: Bool { storage.writable }
    public var preservedFiles: [String] { storage.preservedFiles }
    public var recoveryFilesMayBeTruncated: Bool { storage.recoveryFilesMayBeTruncated }
    public init(directory: URL, faultHook: @escaping @MainActor (DesktopWorkspaceStoreFaultStage) throws -> Void = { _ in }) throws {
        storage = try PrivateArchiveStore(directory: directory, fileName: "desktop-workspaces.json",
            transactionPrefix: ".desktop-workspaces-transaction-", maximumBytes: DesktopWorkspaceArchive.maximumBytes,
            empty: [], decode: { try DesktopWorkspaceArchive.decode($0).workspaces },
            encode: { try DesktopWorkspaceArchive(workspaces: $0).encoded() }, faultHook: faultHook)
    }
    public func save(_ next: [SavedDesktopWorkspace]) throws { try storage.save(next) }
    public func validateCurrent() throws { try storage.validateCurrent() }
}
