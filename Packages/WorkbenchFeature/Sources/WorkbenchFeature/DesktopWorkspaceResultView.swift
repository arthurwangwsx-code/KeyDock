import SwiftUI
import ExecutionCore
import KeyDockUI

struct DesktopWorkspaceResultView: View {
    let result: DesktopWorkspaceRunResult
    let language: String
    var labels: [UUID: String] = [:]
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if geometry.size.width >= 600 { table }
                else { cards }
            }.modifier(KDReadingSurface())
        }
    }
    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 16) {
            GridRow { Text(L("Application")); Text(L("Background launch")); Text(L("Window focus")); Text(L("Window layout")) }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(result.entries.enumerated()), id: \.element.entryID) { index, row in
                GridRow {
                    Text(title(row, index: index)).fontWeight(.medium).lineLimit(2)
                    fact(row.launch); fact(row.focus); fact(row.layout)
                }.accessibilityElement(children: .combine)
            }
        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }
    private var cards: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(result.entries.enumerated()), id: \.element.entryID) { index, row in
                VStack(alignment: .leading, spacing: 11) {
                    Text(title(row, index: index)).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    phase(L("Background launch"), value: row.launch)
                    phase(L("Window focus"), value: row.focus)
                    phase(L("Window layout"), value: row.layout)
                }.accessibilityElement(children: .combine)
                if index < result.entries.count-1 { Divider() }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func title(_ row: DesktopWorkspaceEntryResult, index: Int) -> String {
        labels[row.entryID].map { "\(index+1) · " + $0 } ?? (L("Application") + " \(index+1)")
    }
    private func phase(_ title: String, value: DesktopWorkspacePhaseResult) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            fact(value).font(.callout).multilineTextAlignment(.trailing)
        }
    }
    private func fact(_ value: DesktopWorkspacePhaseResult) -> some View {
        let title: String
        switch value {
        case .confirmed: title = L("Confirmed")
        case .notRequired: title = L("Already running")
        case .notExecuted: title = L("Not dispatched")
        case .declined: title = L("Declined before submission")
        case .unknown: title = L("Submitted · unconfirmed")
        case .unrecorded: title = L("No record · unable to confirm")
        }
        return Text(title).foregroundStyle(value == .notRequired || value == .notExecuted ? Color.secondary : Color.primary).fixedSize(horizontal: false, vertical: true)
    }
}
