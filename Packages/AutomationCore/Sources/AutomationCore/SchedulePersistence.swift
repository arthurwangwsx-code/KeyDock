import Foundation

/// 首期由单App中的单Ledger owner持有；它不是跨进程CAS或分布式租约服务。
/// 多进程宿主必须另外注入真正的独占owner／锁，不得同时实例化多个writer共享文件。
public struct SchedulePersistence: Sendable {
    public let load: @Sendable () throws -> Data?
    public let save: @Sendable (Data) throws -> Void
    public init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void) {
        self.load = load; self.save = save
    }
    /// Foundation适配器不声称抗同用户恶意TOCTOU或实现fsync；高保证宿主可注入已pin目录I/O。
    public static func privateJSON(directory: URL, maxBytes: Int = 2 * 1_048_576) throws -> Self {
        guard directory.isFileURL, maxBytes > 0 else { throw ScheduleError.invalidStorage }
        let directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validate(directory, directory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("scheduled-workflows.json")
        return Self(load: {
            let manager = FileManager.default
            try validate(directory, directory: true)
            guard manager.fileExists(atPath: file.path) else {
                if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw ScheduleError.invalidStorage }
                return nil
            }
            try validate(file, directory: false)
            let size = try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard let size, size.intValue <= maxBytes else { throw ScheduleError.storageTooLarge }
            let data = try Data(contentsOf: file)
            guard data.count <= maxBytes else { throw ScheduleError.storageTooLarge }
            return data
        }, save: { data in
            let manager = FileManager.default
            guard data.count <= maxBytes else { throw ScheduleError.capacityExceeded }
            try validate(directory, directory: true)
            if manager.fileExists(atPath: file.path) { try validate(file, directory: false) }
            else if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw ScheduleError.invalidStorage }
            let temporary = directory.appendingPathComponent(".schedule-" + UUID().uuidString)
            defer { try? manager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if manager.fileExists(atPath: file.path) {
                _ = try manager.replaceItemAt(file, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else { try manager.moveItem(at: temporary, to: file) }
        })
    }
    private static func validate(_ url: URL, directory: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true,
              directory ? values.isDirectory == true : values.isRegularFile == true else { throw ScheduleError.invalidStorage }
    }
}
