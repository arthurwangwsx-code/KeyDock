import Foundation
import CryptoKit
import AICore

/// 只比较选中工具的内容合同，不包含新连接的generation/revision，也不产生任何工具授权。
public extension MCPToolCatalog {
    func selectedContractDigest(names: Set<String>) throws -> String {
        guard names.count <= 32 else { throw MCPClientError.limitExceeded }
        var digest = MCPContractHasher(), catalogBytes = 0
        digest.text("keydock.mcp.selected-contract.v1")
        digest.text(serverID.uuidString); digest.text(configurationRevision.uuidString); digest.integer(UInt64(names.count))
        for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let matches = tools.filter { $0.definition.name.utf8.elementsEqual(name.utf8) }
            guard matches.count == 1, let tool = matches.first,
                  !rejectedTools.contains(where: { $0.originalName.utf8.elementsEqual(tool.originalName.utf8) }) else { throw MCPClientError.catalogChanged }
            guard tool.originalName.utf8.count <= 128, name.utf8.count <= 64, tool.definition.description.utf8.count <= 8_192 else { throw MCPClientError.limitExceeded }
            digest.text(tool.originalName); digest.text(name); digest.text(tool.definition.description)
            digest.byte(tool.untrustedReadOnlyHint.map { $0 ? 2 : 1 } ?? 0)
            var nodes = 0
            try digest.json(.object(tool.definition.parameters), depth: 0, nodes: &nodes)
            // 沿用生产发现的原schema／目录预算；不能因hash投影膨胀拒绝合法目录。
            let schemaBytes = try JSONEncoder().encode(tool.definition.parameters).count
            guard schemaBytes <= 65_536 else { throw MCPClientError.limitExceeded }
            catalogBytes += schemaBytes + tool.definition.description.utf8.count + tool.originalName.utf8.count
            guard catalogBytes <= 262_144 else { throw MCPClientError.limitExceeded }
        }
        return digest.finish()
    }
}

/// v1流式长度分帧：UInt64大端长度／数量／Double位模式，固定JSON tag，避免构造膨胀的第二棵树。
private struct MCPContractHasher {
    private var value = SHA256()
    mutating func byte(_ byte: UInt8) { value.update(data: Data([byte])) }
    mutating func integer(_ integer: UInt64) {
        var bigEndian = integer.bigEndian
        withUnsafeBytes(of: &bigEndian) { value.update(bufferPointer: $0) }
    }
    mutating func text(_ text: String) { integer(UInt64(text.utf8.count)); value.update(data: Data(text.utf8)) }
    mutating func json(_ json: JSONValue, depth: Int, nodes: inout Int) throws {
        nodes += 1; guard nodes <= 8_192, depth <= 32 else { throw MCPClientError.limitExceeded }
        switch json {
        case .null: byte(0)
        case .bool(let value): byte(value ? 2 : 1)
        case .number(let value): guard value.isFinite else { throw MCPClientError.unsupportedSchema }; byte(3); integer(value.bitPattern)
        case .string(let value):
            guard value.utf8.count <= 65_536 else { throw MCPClientError.limitExceeded }; byte(4); text(value)
        case .array(let values):
            guard values.count <= 8_192 else { throw MCPClientError.limitExceeded }; byte(5); integer(UInt64(values.count))
            for value in values { try self.json(value, depth: depth + 1, nodes: &nodes) }
        case .object(let values):
            guard values.count <= 8_192 else { throw MCPClientError.limitExceeded }; byte(6); integer(UInt64(values.count))
            for key in values.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                guard key.utf8.count <= 65_536 else { throw MCPClientError.limitExceeded }; text(key)
                try self.json(values[key]!, depth: depth + 1, nodes: &nodes)
            }
        }
    }
    mutating func finish() -> String { value.finalize().map { String(format: "%02x", $0) }.joined() }
}
