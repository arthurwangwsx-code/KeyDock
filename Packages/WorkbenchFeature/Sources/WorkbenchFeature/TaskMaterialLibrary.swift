import Foundation
import SwiftUI
import ExecutionCore
import KeyDockUI

struct TaskMaterialListRecord: Identifiable, Sendable {
    let handle: TaskMaterialHandle
    let title: String
    let titleKey: String?
    let isTerminal: Bool
    var id: TaskMaterialKey { handle.key }
    var displayTitle: String { titleKey.map(L) ?? title }
}

struct TaskMaterialLibraryView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Retained task content")).font(.title2.weight(.semibold))
            Text(L("Browse saved text independently of current task history. Text is loaded only when you open a record.")).font(.callout).foregroundStyle(.secondary)
            if !store.taskMaterialNotice.rendered().isEmpty { KDInlineNotice(store.taskMaterialNotice.rendered()) }
            if store.taskMaterialRecords.isEmpty {
                KDEmptyState(symbol: "tray", title: L("Nothing available to view"), detail: L("Review and save chosen text from Tasks. Existing saved content stays available when new capture is off."))
            } else {
                List(store.taskMaterialRecords) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(record.displayTitle).font(.headline).lineLimit(2); Spacer(); Text(Date(timeIntervalSince1970: record.handle.header.createdAt), style: .date).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button(L("View retained content…")) { session.prepareRetainedTaskMaterial(record, in: store) }
                            Button(L("Prepare new attempt")) { session.prepareAttempt(.init(store: record.id.receiptStore == .cli ? .cli : .ai, invocationID: record.id.invocationID), in: store) }.disabled(!record.isTerminal)
                        }
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
            HStack {
                Button(L("Refresh")) { Task { await store.refreshTaskMaterialIndex() } }
                Spacer()
                Button(L("Open Privacy settings")) { store.onOpenSettings?(.privacy) }
            }
        }.padding(24).task { await store.refreshTaskMaterialIndex() }
    }
}
