import SwiftUI
import ExecutionCore
import KeyDockUI

struct RunTokenBudgetStatusView: View {
    let snapshot: RunTokenBudgetSnapshot
    private var stateTitle: String {
        switch snapshot.status {
        case .awaitingUsage: L("Waiting for this request's final usage")
        case .verified: L("Usage verified for completed requests")
        case .thresholdReached: L("Reported token threshold reached")
        case .usageUnavailable: L("Usage could not be verified")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Run token threshold") + ": " + String(snapshot.maximumTokens), systemImage: "gauge").fontWeight(.medium)
            Text(L("Known reported tokens") + ": " + (snapshot.knownTokens.map(String.init) ?? L("Unknown")))
            Text(stateTitle)
            if snapshot.status == .verified, let known = snapshot.knownTokens {
                Text(L("Remaining threshold") + ": " + String(max(0, snapshot.maximumTokens - known)))
            }
            if snapshot.status == .usageUnavailable { Text(L("Known counts may be partial. They are not a remaining quota.")) }
            Text(L("This threshold includes input and output tokens and stops later work. A request can exceed it before usage is returned; it is not a billing hard limit."))
        }.font(.caption).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(KDReadingSurface()).accessibilityElement(children: .combine)
    }
}
