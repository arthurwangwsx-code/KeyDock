import Foundation

/// 应用提示保存语义 key，用户、模型和进程内容只按原文保留；不从已翻译字符串反查 key。
public enum LocalizedNotice: Equatable, Sendable {
    case none
    case key(String, suffix: String?)
    case verbatim(String)
    case joined([LocalizedNotice])

    public func rendered(maximumBytes: Int? = nil) -> String {
        let value: String
        switch self {
        case .none: value = ""
        case .key(let key, let suffix):
            value = L(key) + (suffix.map { $0.isEmpty ? "" : " " + $0 } ?? "")
        case .verbatim(let text): value = text
        case .joined(let parts): value = parts.map { $0.rendered() }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return maximumBytes.map { TaskTextLimits.prefix(value, maximumBytes: $0) } ?? value
    }

    /// 同时约束实际保留文本和显示文本；翻译 key 不截断，以免变成无法解析的半个 key。
    public func bounded(maximumBytes: Int) -> LocalizedNotice {
        let budget = max(0, maximumBytes)
        switch self {
        case .none: return .none
        case .verbatim(let text): return .verbatim(TaskTextLimits.prefix(text, maximumBytes: budget))
        case .key(let key, let suffix):
            guard key.utf8.count <= budget else { return .none }
            let available = max(0, budget - key.utf8.count - (suffix?.isEmpty == false ? 1 : 0))
            return .key(key, suffix: suffix.map { TaskTextLimits.prefix($0, maximumBytes: available) })
        case .joined(let parts):
            var result: [LocalizedNotice] = [], remaining = budget
            for part in parts {
                let separator = result.isEmpty ? 0 : 1
                guard remaining > separator else { break }
                let kept = part.bounded(maximumBytes: remaining - separator)
                guard kept.retainedByteCount > 0 else { continue }
                result.append(kept); remaining -= kept.retainedByteCount + separator
            }
            return .joined(result)
        }
    }

    public var retainedByteCount: Int {
        switch self {
        case .none: return 0
        case .verbatim(let text): return text.utf8.count
        case .key(let key, let suffix): return key.utf8.count + (suffix?.utf8.count ?? 0) + (suffix?.isEmpty == false ? 1 : 0)
        case .joined(let parts): return parts.reduce(0) { $0 + $1.retainedByteCount } + max(0, parts.count - 1)
        }
    }

    public func appending(_ message: LocalizedNotice) -> LocalizedNotice {
        let parts: [LocalizedNotice]
        if case .joined(let existing) = self { parts = existing + [message] }
        else { parts = [self, message] }
        return .joined(parts)
    }
}

/// 显式标记应用自有提示；静态文案脚本必须抽取 noticeKey 字面量。
func noticeKey(_ key: String, suffix: String? = nil) -> LocalizedNotice { .key(key, suffix: suffix) }
