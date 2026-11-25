import SwiftUI
import KeyDockUI

struct AttemptPreparationSheetHost: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var presentation: AttemptPreparationPresentation
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { isPresented && !presentation.shouldDismiss }, set: { value in
                if !value { session.cancelAttemptPreparation(presentation.id) }; isPresented = value
            }), onDismiss: { session.attemptPreparationDidDismiss(presentation.id) }) {
                AttemptPreparationView(store: store, session: session, presentation: presentation)
                    .onAppear { session.attemptPreparationDidAppear(presentation.id) }
            }
            .onAppear { if !presentation.shouldDismiss { isPresented = true } else { session.attemptPreparationDidDismiss(presentation.id) } }
            .onChange(of: presentation.shouldDismiss) { _, value in if value { isPresented = false } }
    }
}

private struct AttemptPreparationView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var presentation: AttemptPreparationPresentation
    @FocusState private var inputFocused: Bool
    @State private var definitionExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.clockwise").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Prepare new attempt")).font(.title2.weight(.semibold))
                    Text(L("Review current scope. The previous attempt will stay unchanged.")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            if let review = presentation.review {
                VStack(alignment: .leading, spacing: 12) {
                    Text(review.title).font(.headline).textSelection(.enabled)
                    HStack { Text(L("Previous attempt")).foregroundStyle(.secondary); Spacer(); Text(review.previousState) }.font(.callout)
                    ForEach(review.lines) { line in
                        HStack(alignment: .top, spacing: 16) {
                            Text(line.title).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(line.value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }.font(.callout)
                    }
                }.padding(16).modifier(KDReadingSurface())
                if review.definitionChanged { KDInlineNotice(L("The saved definition differs from the previous attempt. Review the current scope before starting.")) }
                if !review.scopePreview.isEmpty {
                    DisclosureGroup(L("Current execution scope"), isExpanded: $definitionExpanded) {
                        ScrollView { Text(review.scopePreview).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                            .frame(height: 140).modifier(KDReadingSurface())
                    }
                }
                if review.allowsInput {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("New input")).font(.callout.weight(.medium))
                        TextEditor(text: Binding(get: { presentation.input }, set: { presentation.editInput($0) }))
                            .focused($inputFocused).font(.body).scrollContentBackground(.hidden)
                            .frame(minHeight: 100, maxHeight: 160).padding(10).modifier(KDReadingSurface())
                            .accessibilityLabel(L("New attempt input")).disabled(presentation.isSubmitting)
                        Text(L("Only this new input is used. Results are shown without automatic copying or replacement."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(L("A new attempt may repeat completed work. Unknown effects cannot be undone or assumed safe to repeat."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if review.requiresEffectAcknowledgment {
                    Toggle(L("I checked the previous effects and want a new attempt."), isOn: $presentation.effectsChecked)
                        .toggleStyle(.checkbox).disabled(presentation.isSubmitting)
                }
            }
            }
            }.frame(maxHeight: 460)
            if presentation.isReading || presentation.isSubmitting {
                ProgressView(presentation.isSubmitting ? L("Admitting new attempt…") : L("Checking current scope…")).controlSize(.small)
            }
            if !presentation.notice.rendered().isEmpty { KDInlineNotice(presentation.notice.rendered()) }
            HStack {
                Button(L("Cancel")) { session.cancelAttemptPreparation(presentation.id) }.keyboardShortcut(.cancelAction).disabled(presentation.isSubmitting)
                Button(L("Review again")) { presentation.refresh(in: store) }.disabled(presentation.isReading || presentation.isSubmitting)
                Spacer()
                Button(L("Start new attempt")) {
                    store.performUserInputAction { if let id = presentation.review?.id { presentation.confirm(id, in: store) } }
                }.buttonStyle(.borderedProminent).disabled(!presentation.canSubmit(in: store))
            }
        }.padding(24).frame(width: 600).interactiveDismissDisabled(presentation.isSubmitting)
            .environment(\.locale, KDLocalizer.locale)
            .onChange(of: store.configurationExportGeneration) { _, _ in presentation.validateReview(in: store) }
            .onChange(of: store.mcpGeneration) { _, _ in presentation.validateReview(in: store) }
            .onChange(of: store.mcpCatalogEpoch) { _, _ in presentation.validateReview(in: store) }
            .onChange(of: store.isClearingHistory) { _, _ in presentation.validateReview(in: store) }
            .onChange(of: store.isShuttingDown) { _, value in if value { session.invalidateAttemptPreparation() } }
            .task(id: presentation.review?.id) { if presentation.review?.allowsInput == true { await Task.yield(); inputFocused = true } }
            .onChange(of: presentation.review?.id) { _, _ in definitionExpanded = presentation.review?.definitionChanged == true }
    }
}
