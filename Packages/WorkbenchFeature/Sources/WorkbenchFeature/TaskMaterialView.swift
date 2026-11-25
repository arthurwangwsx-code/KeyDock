import SwiftUI
import KeyDockUI

struct TaskMaterialSheetHost: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var presentation: TaskMaterialPresentation
    @State private var isPresented = false
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { isPresented && !presentation.shouldDismiss }, set: { value in
                if !value { session.cancelTaskMaterial(presentation.id) }; isPresented = value
            }), onDismiss: { session.taskMaterialDidDismiss(presentation.id) }) {
                TaskMaterialView(store: store, session: session, presentation: presentation)
                    .onAppear { session.taskMaterialDidAppear(presentation.id) }
            }
            .onAppear { if !presentation.shouldDismiss { isPresented = true } else { session.taskMaterialDidDismiss(presentation.id) } }
            .onChange(of: presentation.shouldDismiss) { _, value in if value { isPresented = false } }
    }
}

private struct TaskMaterialView: View {
    @ObservedObject var store: WorkbenchModel
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var presentation: TaskMaterialPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: presentation.mode == .saveReview ? "tray.and.arrow.down" : "doc.text.magnifyingglass").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.mode == .saveReview ? L("Review task content") : L("Retained task content")).font(.title2.weight(.semibold))
                    Text(presentation.displayTitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text(L("Saved text expires after 7 days; files are removed during the next app maintenance. It may contain sensitive information. Only fields you select are saved.")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                if let buffer = presentation.buffer { TaskMaterialFieldsView(buffer: buffer, presentation: presentation) }
                if let handle = presentation.handle {
                    Text(L("Expires") + " · " + Date(timeIntervalSince1970: handle.header.expiresAt).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(KDLocalizer.locale)))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }.frame(minHeight: 160, maxHeight: 420)
            if presentation.isReading || presentation.isMutating { ProgressView(L("Working with task content…")).controlSize(.small) }
            if !presentation.notice.rendered().isEmpty { KDInlineNotice(presentation.notice.rendered()) }
            if presentation.mode == .view, presentation.phase == .ready {
                Toggle(L("Delete this saved content from this Mac"), isOn: $presentation.deletionChecked).toggleStyle(.checkbox)
            }
            HStack {
                Button(L("Close")) { session.cancelTaskMaterial(presentation.id) }.keyboardShortcut(.cancelAction).disabled(presentation.isMutating)
                Button(L("Review again")) { presentation.refresh(in: store) }.disabled(presentation.isReading || presentation.isMutating)
                Spacer()
                if presentation.mode == .saveReview {
                    Button(L("Save selected content")) { presentation.save(presentation.reviewID, in: store) }
                        .buttonStyle(.borderedProminent).disabled(!presentation.canSave)
                } else {
                    Button(L("Delete saved content"), role: .destructive) { presentation.delete(presentation.reviewID, in: store) }
                        .disabled(presentation.phase != .ready || !presentation.deletionChecked)
                }
            }
        }.padding(24).frame(width: 620).interactiveDismissDisabled(presentation.isMutating)
            .environment(\.locale, KDLocalizer.locale)
            .onChange(of: store.taskMaterialGeneration) { _, _ in presentation.contentChanged(in: store) }
            .onChange(of: store.isShuttingDown) { _, value in if value { session.invalidateTaskMaterialPresentation() } }
    }
}

private struct TaskMaterialFieldsView: View {
    @ObservedObject var buffer: TaskMaterialBuffer
    @ObservedObject var presentation: TaskMaterialPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let material = buffer.material {
                if let input = material.input { field(.input, title: L("Original run input"), text: input) }
                else if presentation.mode == .saveReview { Text(L("Original input was not captured for this run.")).font(.caption).foregroundStyle(.secondary) }
                if let output = material.visibleResult {
                    field(.visibleResult, title: L("Visible result"), text: output)
                    if material.resultKind == .agentIncludingToolReturns { Text(L("This Agent result includes model text and tool returns. Review it before selecting.")).font(.caption).foregroundStyle(.secondary) }
                    if material.resultWasPartial == true { Label(L("Partial result at capture time"), systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
                    if let time = material.resultCapturedAt { Text(Date(timeIntervalSince1970: time), style: .time).font(.caption).foregroundStyle(.secondary) }
                }
                if let checkpoint = material.successfulCheckpoint {
                    field(.successfulCheckpoint, title: L("Latest successful step") + " · " + String(checkpoint.stepIndex + 1), text: checkpoint.input)
                    Text(L("Step output")).font(.caption).foregroundStyle(.secondary)
                    ReadOnlyTextPreview(text: checkpoint.output, accessibilityLabel: L("Step output"), monospaced: true).frame(height: 140).modifier(KDReadingSurface())
                    Text(L("This is saved text only. It cannot resume or repeat a workflow step.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func field(_ field: TaskMaterialField, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.mode == .saveReview {
                Toggle(title, isOn: Binding(get: { presentation.selectedFields.contains(field) }, set: { value in
                    if value { presentation.selectedFields.insert(field) } else { presentation.selectedFields.remove(field) }
                })).toggleStyle(.checkbox).disabled(presentation.phase != .ready)
            } else { Text(title).font(.callout.weight(.medium)) }
            ReadOnlyTextPreview(text: text, accessibilityLabel: title, monospaced: true).frame(height: 140).modifier(KDReadingSurface())
        }
    }
}
