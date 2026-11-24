import Foundation

public enum ClipboardSeparator: String, CaseIterable, Codable, Sendable {
    case newline, blankLine, space, none
    public var text: String { switch self { case .newline: "\n"; case .blankLine: "\n\n"; case .space: " "; case .none: "" } }
}

public enum ClipboardCompositionError: Error, Equatable { case invalidSelection, missingItem, tooLarge, unsupported }

/// 一个有界、准确的合并正文；不包含粘贴目标或执行许可。
public struct ClipboardComposition: Equatable, Sendable {
    public static let maximumItems = 20
    public static let maximumBytes = 1_048_576
    public let ids: [String]
    public let separator: ClipboardSeparator
    public let text: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Swift字符串相等会合并Unicode等价写法；准确预览必须比较实际UTF8字节。
        lhs.ids == rhs.ids && lhs.separator == rhs.separator && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    public static func validate(ids: [String]) throws {
        guard !ids.isEmpty, ids.count <= maximumItems, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") }) else { throw ClipboardCompositionError.invalidSelection }
    }

    /// 读取端先检查剩余字节预算，不能先复制所有正文后再joined。
    public static func read(ids: [String], separator: ClipboardSeparator,
                            body: (String, Int) throws -> String?) throws -> Self {
        try validate(ids: ids)
        var result = ""
        for (index, id) in ids.enumerated() {
            try Task.checkCancellation()
            let delimiter = index == 0 ? "" : separator.text
            let remaining = maximumBytes - result.utf8.count - delimiter.utf8.count
            guard remaining >= 0 else { throw ClipboardCompositionError.tooLarge }
            guard let value = try body(id, remaining), !value.isEmpty else { throw ClipboardCompositionError.missingItem }
            guard value.utf8.count <= remaining else { throw ClipboardCompositionError.tooLarge }
            result.append(delimiter); result.append(value)
        }
        return Self(ids: ids, separator: separator, text: result)
    }
}
