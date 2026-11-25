import SwiftUI
import KeyDockUI

/// 直到实际dismiss保留同一owner，闭包固定呈现ID，不采用后来选中的动态目标。
struct SourceRemovalSheetHost: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var presentation: SourceRemovalPresentation
    let cancel: (UUID) -> Void
    let didAppear: (UUID) -> Void
    let didDismiss: (UUID) -> Void
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { isPresented && !presentation.invalidated && !presentation.removed }, set: { value in
                if !value { cancel(presentation.id) }; isPresented = value
            }), onDismiss: { didDismiss(presentation.id) }) {
                SourceRemovalView(store: store, presentation: presentation, cancel: { cancel(presentation.id) })
                    .onAppear { didAppear(presentation.id) }
            }
            .onAppear { if !presentation.invalidated { isPresented = true } else { didDismiss(presentation.id) } }
            .onChange(of: presentation.invalidated || presentation.removed) { _, value in if value { isPresented = false } }
    }
}

private struct SourceRemovalView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var presentation: SourceRemovalPresentation
    let cancel: () -> Void
    var body: some View {
        let reviewID = presentation.review?.id
        VStack(alignment: .leading, spacing: 16) {
            Text(presentation.target.isWorkflow ? L("Remove workflow?") : L("Remove MCP source?")).font(.title2.bold())
            if let review = presentation.review {
                Text(review.name).font(.headline).textSelection(.enabled)
                if presentation.target.isWorkflow {
                    Text(L("Schedules, including disabled ones, and collections must stop referencing this workflow first. Its shortcut, favorite and alias are removed together. Running workflows keep their snapshot.")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L("Agent source and tool references must be removed first. Confirming removal pauses this source and cancels its active calls. Completed effects cannot be undone. Stored keys and imported text are kept.")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !review.dependencies.isEmpty {
                    Text(L("This item is still in use. Remove its references, then review again.")).font(.callout)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(review.dependencies) { Text($0.title).frame(maxWidth: .infinity, alignment: .leading) }
                        }.padding(12)
                    }.frame(maxHeight: 180).modifier(KDReadingSurface())
                }
            }
            if presentation.isBusy { ProgressView(presentation.isConfirming ? L("Removing source…") : L("Checking references…")) }
            if !presentation.notice.rendered().isEmpty { KDInlineNotice(presentation.notice.rendered()) }
            if !presentation.detail.rendered().isEmpty { KDInlineNotice(presentation.detail.rendered()) }
            HStack {
                Button(L("Cancel"), action: cancel).keyboardShortcut(.cancelAction).disabled(presentation.isConfirming)
                Button(L("Review again")) { presentation.refresh(in: store) }.disabled(presentation.isBusy)
                Spacer()
                Button(L("Remove"), role: .destructive) { if let reviewID { presentation.confirm(reviewID, in: store) } }.disabled(!presentation.canConfirm)
                    .accessibilityLabel(L("Remove") + " · " + (presentation.review?.name ?? ""))
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(presentation.isConfirming)
    }
}
