import Foundation
import KeyDockUI

/// 对机器生成的输入明确冻结最终文案语言，不能让模型从JSON字段猜用户语言。
enum AIResponseLanguage: String, Sendable {
    case english = "en", simplifiedChinese = "zh-Hans"
    init(preference: String) {
        let effective = preference == "system" ? KDLocalizer.resolvedLanguage : KDLocalizer.resolveLanguage(preference: preference, preferredLanguages: Locale.preferredLanguages)
        self = effective == "zh-Hans" ? .simplifiedChinese : .english
    }
    var finalResponseInstruction: String {
        switch self {
        case .english: "Write the final response in English (en)."
        case .simplifiedChinese: "Write the final response in Simplified Chinese (zh-Hans)."
        }
    }
}
