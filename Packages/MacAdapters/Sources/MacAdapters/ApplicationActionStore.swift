import Foundation
import CommandCore

public typealias ApplicationActionStoreError = ArchiveStoreError
public typealias ApplicationActionStoreFaultStage = ArchiveStoreFaultStage

/// 保留原公开接口与磁盘格式，共用固定目录身份的字节事务。
@MainActor public final class ApplicationActionStore {
    private let storage: PrivateArchiveStore<[SavedApplicationAction]>
    public var actions: [SavedApplicationAction] { storage.value }
    public var writable: Bool { storage.writable }
    public var preservedFiles: [String] { storage.preservedFiles }
    public var recoveryFilesMayBeTruncated: Bool { storage.recoveryFilesMayBeTruncated }
    public init(directory: URL,
                faultHook: @escaping @MainActor (ApplicationActionStoreFaultStage) throws -> Void = { _ in }) throws {
        storage = try PrivateArchiveStore(directory: directory, fileName: "application-actions.json",
            transactionPrefix: ".application-actions-transaction-", maximumBytes: ApplicationActionArchive.maximumBytes,
            empty: [], decode: { try ApplicationActionArchive.decode($0).actions },
            encode: { try ApplicationActionArchive(actions: $0).encoded() }, faultHook: faultHook)
    }
    public func save(_ next: [SavedApplicationAction]) throws { try storage.save(next) }
}
