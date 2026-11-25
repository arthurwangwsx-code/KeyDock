import Foundation

struct TaskMaterialRemovalTarget: Codable, Sendable {
    let key: TaskMaterialKey
    let version: TaskMaterialVersion
}

/// 只表达用户已确认的本机材料清理，不是任何工具／网络／执行授权。
struct TaskMaterialDeletionIntent: Codable, Sendable {
    let id: UUID
    let all: Bool
    let keys: [TaskMaterialKey]
    let targets: [TaskMaterialRemovalTarget]
    func validates() -> Bool {
        if all { return keys.isEmpty && targets.isEmpty }
        return !keys.isEmpty || !targets.isEmpty
            ? keys.count + targets.count <= 200 && Set(keys).count == keys.count &&
                Set(targets.map(\.key)).count == targets.count &&
                Set(keys).isDisjoint(with: targets.map(\.key)) && targets.allSatisfy { $0.version.revision > 0 }
            : false
    }
    func covers(_ key: TaskMaterialKey, version: TaskMaterialVersion? = nil) -> Bool {
        all || keys.contains(key) || targets.contains { $0.key == key && (version == nil || $0.version == version) }
    }
}

/// 首次写明文前持久化。失败后的临时文件不能因为进程退出而变成“空库”。
struct TaskMaterialPendingWrite: Codable, Sendable {
    let key: TaskMaterialKey
    let proposed: TaskMaterialVersion
    let previous: TaskMaterialVersion?
    let payloadSHA256: String
    let fileBytes: Int
    func validates() -> Bool {
        guard proposed.revision > 0, (12...TaskMaterialLimits.recordBytes).contains(fileBytes),
              payloadSHA256.utf8.count == 64,
              payloadSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        if let previous {
            return previous.revision > 0 && previous.revision < UInt64.max && proposed.identity == previous.identity && proposed.revision == previous.revision + 1
        }
        return proposed.revision == 1
    }
}

struct TaskMaterialControl: Codable, Sendable {
    let formatVersion: Int
    let epoch: UUID
    var deletion: TaskMaterialDeletionIntent?
    var pendingWrite: TaskMaterialPendingWrite?
    static func empty() -> Self { .init(formatVersion: 1, epoch: UUID()) }
    func validate() throws {
        guard formatVersion == 1, deletion?.validates() != false, pendingWrite?.validates() != false else { throw TaskMaterialError.malformedControl }
        if let pendingWrite, deletion?.covers(pendingWrite.key) == true { throw TaskMaterialError.malformedControl }
    }
    func encoded() throws -> Data {
        try validate()
        let bytes = try TaskMaterialFormat.encoder().encode(self)
        guard bytes.count <= TaskMaterialLimits.controlBytes else { throw TaskMaterialError.capacity }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            guard bytes.count <= TaskMaterialLimits.controlBytes,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys).isSubset(of: ["formatVersion", "epoch", "deletion", "pendingWrite"]),
                  Set(["formatVersion", "epoch"]).isSubset(of: Set(object.keys)) else { throw TaskMaterialError.malformedControl }
            if let deletion = object["deletion"], !(deletion is NSNull) {
                guard let value = deletion as? [String: Any], Set(value.keys) == Set(["id", "all", "keys", "targets"]) else { throw TaskMaterialError.malformedControl }
                guard let keys = value["keys"] as? [Any], let targets = value["targets"] as? [Any], keys.count + targets.count <= 200 else { throw TaskMaterialError.malformedControl }
                for key in keys { try requireKey(key) }
                for target in targets {
                    guard let entry = target as? [String: Any], Set(entry.keys) == Set(["key", "version"]) else { throw TaskMaterialError.malformedControl }
                    try requireKey(entry["key"]); try requireVersion(entry["version"])
                }
            }
            if let pending = object["pendingWrite"], !(pending is NSNull) {
                guard let value = pending as? [String: Any], Set(value.keys).isSubset(of: ["key", "proposed", "previous", "payloadSHA256", "fileBytes"]),
                      Set(["key", "proposed", "payloadSHA256", "fileBytes"]).isSubset(of: Set(value.keys)) else { throw TaskMaterialError.malformedControl }
                try requireKey(value["key"]); try requireVersion(value["proposed"])
                if let previous = value["previous"], !(previous is NSNull) { try requireVersion(previous) }
            }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            try value.validate(); return value
        } catch { throw TaskMaterialError.malformedControl }
    }
    private static func requireKey(_ value: Any?) throws {
        guard let value = value as? [String: Any], Set(value.keys) == Set(["receiptStore", "invocationID", "receiptRecordIdentity"]) else { throw TaskMaterialError.malformedControl }
    }
    private static func requireVersion(_ value: Any?) throws {
        guard let value = value as? [String: Any], Set(value.keys) == Set(["identity", "revision"]) else { throw TaskMaterialError.malformedControl }
    }
}

enum TaskMaterialNames {
    static func temporaryKey(_ name: String) -> TaskMaterialKey? {
        guard name.hasPrefix(".material-v1-"), name.hasSuffix(".tmp") else { return nil }
        let stem = String(name.dropFirst(".material-v1-".count).dropLast(4))
        guard (113...114).contains(stem.utf8.count),
              stem.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        let suffix = String(stem.suffix(36))
        guard let id = UUID(uuidString: suffix), id.uuidString.lowercased() == suffix,
              stem.dropLast(36).last == "-" else { return nil }
        return TaskMaterialKey.fromFileName(String(stem.dropLast(37)) + ".kdmaterial")
    }
    static func isControlTemporary(_ name: String) -> Bool {
        guard name.hasPrefix(".control-v1-"), name.hasSuffix(".tmp") else { return false }
        let raw = String(name.dropFirst(".control-v1-".count).dropLast(4))
        return UUID(uuidString: raw).map { $0.uuidString.lowercased() == raw } ?? false
    }
    static func isManaged(_ name: String) -> Bool {
        TaskMaterialKey.fromFileName(name) != nil || temporaryKey(name) != nil || isControlTemporary(name)
    }
    static func key(_ name: String) -> TaskMaterialKey? { TaskMaterialKey.fromFileName(name) ?? temporaryKey(name) }
}
