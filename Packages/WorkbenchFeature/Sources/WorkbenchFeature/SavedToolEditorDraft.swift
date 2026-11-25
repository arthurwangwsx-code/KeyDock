import Foundation
import CryptoKit
import CommandCore

/// 目录、编辑与删除共用字节身份；Unicode规范等价也不能掩盖定义变化。
enum SavedItemIdentity {
    static func fingerprint<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct SnippetEditorDraft: Equatable {
    var editingID: UUID? = nil
    var expectedFingerprint: String? = nil
    var name = ""
    var text = ""
}

extension WorkspaceSession {
    func editSnippet(_ value: SnippetDefinition) {
        guard savedToolRemoval == nil else { return }
        snippetDraft = SnippetEditorDraft(editingID: value.id, expectedFingerprint: SavedItemIdentity.fingerprint(value), name: value.name, text: value.text)
    }
    func newSnippet() { guard savedToolRemoval == nil else { return }; snippetDraft = SnippetEditorDraft() }
    @discardableResult func saveSnippet(in store: WorkbenchModel) -> Bool {
        guard savedToolRemoval == nil else { return false }
        let value = snippetDraft
        if let id = value.editingID, !store.validateSavedToolEdit(.snippet(id), expected: value.expectedFingerprint) { return false }
        guard store.saveSnippet(id: value.editingID, name: value.name, text: value.text) else { return false }
        newSnippet()
        return true
    }
}
