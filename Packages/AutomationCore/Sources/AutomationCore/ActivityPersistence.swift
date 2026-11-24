import Foundation

/// 宿主可注入现有的目录pinning／原子写适配器；Core不持有UI或第二套业务任务状态。
public struct ActivityPersistence: Sendable {
    public let load: @Sendable () throws -> Data?
    public let save: @Sendable (Data) throws -> Void
    public init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void) {
        self.load = load; self.save = save
    }

    /// Foundation本地元数据适配器；私有目录、原子替换、拒绝已观察到的symlink／非普通文件。
    /// 它不构成OS沙箱；有同用户恶意竞争写者的宿主应注入已pin目录的存储适配器。
    public static func privateJSON(directory: URL, maxLoadBytes: Int = 8 * 1_048_576) throws -> Self {
        guard directory.isFileURL, maxLoadBytes > 0 else { throw ActivityError.invalidStorage }
        let manager = FileManager.default
        let directory = directory.standardizedFileURL
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validate(directory, isDirectory: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("activity-metadata.json", isDirectory: false)
        return Self(load: {
            let manager = FileManager.default
            try validate(directory, isDirectory: true)
            guard manager.fileExists(atPath: file.path) else {
                // fileExists对悬空symlink返回false，因此另外读取资源类型。
                if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw ActivityError.invalidStorage }
                return nil
            }
            try validate(file, isDirectory: false)
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= maxLoadBytes else { throw ActivityError.storageTooLarge }
            let data = try Data(contentsOf: file)
            guard data.count <= maxLoadBytes else { throw ActivityError.storageTooLarge }
            return data
        }, save: { data in
            let manager = FileManager.default
            guard data.count <= maxLoadBytes else { throw ActivityError.capacityExceeded }
            try validate(directory, isDirectory: true)
            if manager.fileExists(atPath: file.path) { try validate(file, isDirectory: false) }
            else if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw ActivityError.invalidStorage }
            let temporary = directory.appendingPathComponent(".activity-" + UUID().uuidString)
            defer { try? manager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if manager.fileExists(atPath: file.path) {
                _ = try manager.replaceItemAt(file, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else { try manager.moveItem(at: temporary, to: file) }
        })
    }

    private static func validate(_ url: URL, isDirectory: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true,
              isDirectory ? values.isDirectory == true : values.isRegularFile == true else { throw ActivityError.invalidStorage }
    }
}
