import SwiftUI
import KeyDockUI

struct AIDraftCloseReviewView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject private var document: AIDraftDocument
    let intent: AIDraftCloseIntent
    @Environment(\.dismiss) private var dismiss
    init(store: WorkbenchModel, intent: AIDraftCloseIntent) {
        self.store = store; self.intent = intent; document = intent.document
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Label(L("Close this AI draft?"),systemImage:"doc.badge.ellipsis").font(.title3.weight(.semibold))
            VStack(alignment:.leading,spacing:8) {
                Text(intent.sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(intent.preview.isEmpty ? L("No input") : intent.preview).font(.body).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
            }.padding(12).modifier(KDReadingSurface())
            Text(L("KeyDock cancels this draft’s requests and waits for them to finish before discarding its input and source. Task results keep their source labels, but selection replacement is disabled. Command editors already opened from suggestions are kept. Hiding the window keeps the draft.")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if document.isClosing { HStack { ProgressView().controlSize(.small); Text(L("Closing draft after its tasks finish…")).font(.caption) } }
            else if !intent.isCurrent(in:store) { KDInlineNotice(L("This draft changed. Cancel and reopen the close review to check its current input.")) }
            HStack {
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Close draft"),role:.destructive) { Task { if await intent.perform(in:store) { dismiss() } } }
                    .buttonStyle(.borderedProminent).disabled(!intent.isCurrent(in:store))
            }.disabled(document.isClosing)
        }.padding(24).frame(width:480).environment(\.locale,KDLocalizer.locale)
    }
}
