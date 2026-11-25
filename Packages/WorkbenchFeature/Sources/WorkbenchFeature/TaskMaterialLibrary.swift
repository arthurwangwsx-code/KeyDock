import Foundation
import SwiftUI
import ExecutionCore
import KeyDockUI

enum TaskMaterialIndexPhase: Equatable { case idle, loading, ready, failed }

struct TaskMaterialListRecord: Identifiable, Sendable {
    let handle: TaskMaterialHandle
    let title: String
    let titleKey: String?
    let isTerminal: Bool
    var id: TaskMaterialKey { handle.key }
    var displayTitle: String { titleKey.map(L) ?? title }
    var savedAtText: String {
        Date(timeIntervalSince1970: handle.header.createdAt).formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(KDLocalizer.locale))
    }
}

struct TaskMaterialLibraryView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Retained task content")).font(.title2.weight(.semibold))
            Text(L("Browse saved text independently of current task history. Text is loaded only when you open a record.")).font(.callout).foregroundStyle(.secondary)
            if !store.taskMaterialNotice.rendered().isEmpty { KDInlineNotice(store.taskMaterialNotice.rendered()) }
            if store.taskMaterialIndexPhase == .loading { ProgressView(L("Loading saved content…")).controlSize(.small) }
            if store.taskMaterialRecords.isEmpty {
                switch store.taskMaterialIndexPhase {
                case .idle: Text(L("Refresh to load saved content.")).foregroundStyle(.secondary)
                case .loading: EmptyView()
                case .failed: KDEmptyState(symbol: "exclamationmark.triangle", title: L("Saved content could not be read"), detail: L("Refresh to try again. Existing files have been kept."))
                case .ready: KDEmptyState(symbol: "tray", title: L("Nothing available to view"), detail: L("Review and save chosen text from Tasks. Existing saved content stays available when new capture is off."))
                }
            } else {
                List(Array(store.taskMaterialRecords.enumerated()), id: \.element.id) { entry in
                    let record = entry.element
                    let context = record.displayTitle + " · " + record.savedAtText + " · " + L("Saved item") + " " + String(entry.offset + 1)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(String(entry.offset + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityLabel(L("Saved item") + " " + String(entry.offset + 1))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.displayTitle).font(.headline).lineLimit(2)
                                Text(record.savedAtText).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        HStack {
                            Button(L("View retained content…")) { session.prepareRetainedTaskMaterial(record, in: store) }
                                .accessibilityLabel(L("View retained content…") + " · " + context)
                            Button(L("Prepare new attempt")) { session.prepareAttempt(.init(store: record.id.receiptStore == .cli ? .cli : .ai, invocationID: record.id.invocationID), in: store) }.disabled(!record.isTerminal)
                                .accessibilityLabel(L("Prepare new attempt") + " · " + context)
                        }
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
            HStack {
                Button(L("Refresh")) { Task { await store.refreshTaskMaterialIndex() } }.disabled(store.taskMaterialIndexPhase == .loading)
                Spacer()
                Button(L("Open Privacy settings")) { store.onOpenSettings?(.privacy) }
            }
        }.padding(24).task { await store.refreshTaskMaterialIndex() }
    }
}
