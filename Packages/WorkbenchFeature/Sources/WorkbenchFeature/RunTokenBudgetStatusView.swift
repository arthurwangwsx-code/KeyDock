import SwiftUI
import ExecutionCore
import KeyDockUI

struct RunTokenBudgetStatusView: View {
    let snapshot: RunTokenBudgetSnapshot
    let language: String
    private var stateTitle: String {
        switch snapshot.status {
        case .awaitingUsage: L("Waiting for this request's final usage")
        case .verified: L("Usage verified for completed requests")
        case .thresholdReached: L("Reported token threshold reached")
        case .usageUnavailable: L("Usage could not be verified")
        }
    }
    private var stateSymbol: String {
        switch snapshot.status {
        case .awaitingUsage: "hourglass"
        case .verified: "checkmark.circle"
        case .thresholdReached: "pause.circle"
        case .usageUnavailable: "exclamationmark.circle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Run token threshold") + ": " + String(snapshot.maximumTokens), systemImage: "gauge").fontWeight(.semibold).monospacedDigit()
            Text(L("Known reported tokens") + ": " + (snapshot.knownTokens.map(String.init) ?? L("Unknown"))).monospacedDigit()
            Label(stateTitle, systemImage: stateSymbol).fontWeight(.medium)
            if snapshot.status == .verified, let known = snapshot.knownTokens {
                Text(L("Remaining threshold") + ": " + String(max(0, snapshot.maximumTokens - known)))
            }
            if snapshot.status == .usageUnavailable { Text(L("Known counts may be partial. They are not a remaining quota.")).font(.caption).foregroundStyle(.secondary) }
            Text(L("This threshold includes input and output tokens and stops later work. A request can exceed it before usage is returned; it is not a billing hard limit."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 720, alignment: .leading)
        }.font(.callout).foregroundStyle(.primary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(KDReadingSurface()).accessibilityElement(children: .combine)
    }
}
