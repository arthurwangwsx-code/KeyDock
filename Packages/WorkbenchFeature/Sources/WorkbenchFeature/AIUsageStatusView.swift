import SwiftUI

/// 两个结果入口共用；部分用量只展示已报告数值，始终与费用未知区分。
struct AIUsageStatusView: View {
    let summary: AIUsageSummary
    // 显式参与SwiftUI值比较，语言变化只重算文案，不重建有状态父视图。
    let language: String
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(summary.stateTitle).fontWeight(.medium)
                Spacer(minLength: 0)
                if summary.state != .notRequested {
                    Text(L("Input tokens") + ": " + summary.inputText)
                    Text(L("Output tokens") + ": " + summary.outputText)
                }
            }
            if summary.state == .partial { Text(L("Reported counts may be incomplete. Missing values are not zero.")) }
            Text(summary.costText)
        }.font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}
