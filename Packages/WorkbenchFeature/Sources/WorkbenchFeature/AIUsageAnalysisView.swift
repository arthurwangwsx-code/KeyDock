import SwiftUI

/// 与可选的动作行为统计分开；只消费本地用量账本，不把费用历史加入AI总结。
struct AIUsageAnalysisSection: View {
    @Environment(\.locale) private var displayLocale
    @Environment(\.timeZone) private var displayTimeZone
    @ObservedObject var store: WorkbenchModel
    @State private var days = 7

    var body: some View {
        Section(L("AI usage and estimates")) {
            Text(L("Local request metadata only. Prices are frozen when a run starts. Estimates are not provider bills; currencies are kept separate.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("AI usage time range"), selection: $days) {
                Text(L("Last 7 days")).tag(7)
                Text(L("Last 30 days")).tag(30)
                Text(L("Last 90 days")).tag(90)
            }.pickerStyle(.segmented)
            HStack {
                Button(L("Refresh AI usage")) { store.invalidateUsageAnalysis() }
                Button(L("Configure rates")) { store.onOpenSettings?(.aiService) }
                Spacer()
                if store.usageAnalysisLoading { ProgressView().controlSize(.small).accessibilityLabel(L("Reading AI usage")) }
            }
            if let report = store.usageAnalysisReport {
                HStack {
                    Text(report.from, format: dateFormat)
                    Text("→")
                    Text(report.to, format: dateFormat)
                }.font(.caption).foregroundStyle(.secondary).accessibilityElement(children: .combine)
                Text(L("Displayed time zone") + ": " + displayTimeZone.identifier).font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("Recorded model requests"), value: String(report.calls))
                LabeledContent(L("Reported input tokens"), value: report.inputTokens.map(String.init) ?? L("Unknown"))
                LabeledContent(L("Reported output tokens"), value: report.outputTokens.map(String.init) ?? L("Unknown"))
                ForEach(report.amounts, id: \.currency) { amount in
                    LabeledContent(L("Estimate from known usage")) {
                        Text(amount.currency + " " + amount.amount).monospacedDigit().textSelection(.enabled)
                    }
                }
                if report.amounts.isEmpty {
                    Text(L("No priced subtotal is available. Missing rates or usage are not treated as zero.")).font(.caption).foregroundStyle(.secondary)
                }
                if report.hasCoverageGaps {
                    Label(L("Partial coverage"), systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Text(L("Only retained, readable request records are included. Missing, cleared, expired, incomplete and unpriced usage can leave gaps.")).font(.caption).foregroundStyle(.secondary)
                }
                if report.unpricedCalls > 0 { LabeledContent(L("Requests without a usable rate"), value: String(report.unpricedCalls)) }
                if report.incompleteCalls > 0 { LabeledContent(L("Requests with incomplete usage"), value: String(report.incompleteCalls)) }
                if report.incompleteWorkflows > 0 { LabeledContent(L("Incomplete workflow records"), value: String(report.incompleteWorkflows)) }
                if report.readProblems + report.invalidRecords + report.duplicateAttempts > 0 {
                    LabeledContent(L("Read or validation gaps"), value: String(report.readProblems + report.invalidRecords + report.duplicateAttempts))
                }
                if report.legacyRecords > 0 {
                    LabeledContent(L("Legacy records without request snapshots"), value: String(report.legacyRecords))
                    LabeledContent(L("Legacy reported input tokens"), value: report.legacyInputTokens.map(String.init) ?? L("Unknown"))
                    LabeledContent(L("Legacy reported output tokens"), value: report.legacyOutputTokens.map(String.init) ?? L("Unknown"))
                    Text(L("Legacy usage is grouped by record date and kept separate from request totals. Current rates are never applied to old records.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Requests use their start time in this range; the end is exclusive. The ledger retains up to 90 days within count and storage limits. Action statistics and their AI summary do not include this ledger.")).font(.caption).foregroundStyle(.secondary)
            } else if !store.usageAnalysisLoading {
                Text(L("AI usage could not be read. Refresh to try again.")).font(.caption).foregroundStyle(.secondary)
            }
        }.task(id: "\(days)-\(store.usageAnalysisRefreshToken)") { await store.refreshAIUsageAnalysis(days: days) }
    }
    private var dateFormat: Date.FormatStyle { .init(date: .abbreviated, time: .shortened, locale: displayLocale, timeZone: displayTimeZone) }
}
