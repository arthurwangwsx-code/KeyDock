import Foundation
import AICore

/// 宿主的文本预算；按 UTF-8 字节计数，始终保留合法 UTF-8 前缀。
enum TaskTextLimits {
    static let inputBytes = 131_072
    static let outputBytes = 1_048_576

    static func prefix(_ text: String, maximumBytes: Int) -> String {
        let bytes = text.utf8
        guard maximumBytes > 0 else { return "" }
        guard bytes.count > maximumBytes else { return text }
        var end = bytes.index(bytes.startIndex, offsetBy: maximumBytes)
        while end != bytes.startIndex && bytes[end] & 0xc0 == 0x80 {
            end = bytes.index(before: end)
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

extension WorkbenchModel {
    @discardableResult func appendOutput(_ id: UUID, text: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let remaining = max(0, TaskTextLimits.outputBytes - tasks[index].output.utf8.count)
        let complete = text.utf8.count <= remaining
        tasks[index].output += TaskTextLimits.prefix(text, maximumBytes: remaining)
        if !complete { tasks[index].outputIsIncomplete = true }
        return complete
    }

    func appendAIOutput(_ id: UUID, text: String) throws {
        guard appendOutput(id, text: text) else { throw AIProviderError.outputLimit }
    }

    func markIncompleteOutput(_ id: UUID, notice: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].outputIsIncomplete = true
        if let notice { tasks[index].notice = notice }
    }

    func markIncompleteAIError(_ error: Error, id: UUID) {
        switch error as? AIProviderError {
        case .outputLimit?, .tokenLimit?, .truncatedStream?: markIncompleteOutput(id)
        default: break
        }
    }
}
