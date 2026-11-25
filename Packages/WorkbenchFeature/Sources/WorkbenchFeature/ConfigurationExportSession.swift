import Foundation
import Combine

struct ConfigurationExportSaveAttempt: Identifiable, Sendable {
    let id = UUID()
    let snapshot: FrozenConfigurationExport
}
enum ConfigurationExportSaveOutcome { case saved, cancelled, failed }

@MainActor final class ConfigurationExportPresentation: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var sections = Set(ConfigurationExportSection.allCases)
    @Published private(set) var snapshot: FrozenConfigurationExport?
    @Published private(set) var saveAttempt: ConfigurationExportSaveAttempt?
    @Published private(set) var notice: LocalizedNotice = .none
    @Published private(set) var invalidated = false
    @Published private(set) var isCapturing = false
    @Published private(set) var previewIsCurrent = false
    private(set) var appeared = false
    private var captureID: UUID?
    private var captureTask: Task<Void, Never>?
    var isSaving: Bool { saveAttempt != nil }
    var canSave: Bool { !invalidated && !isSaving && !isCapturing && previewIsCurrent && snapshot != nil }

    func didAppear() { if !invalidated { appeared = true } }
    func setSection(_ section: ConfigurationExportSection, selected: Bool) {
        guard !invalidated, !isSaving, sections.contains(section) != selected else { return }
        cancelCapture()
        if selected { sections.insert(section) } else { sections.remove(section) }
        previewIsCurrent = false; notice = .none
    }
    func refresh(capture: @escaping @MainActor @Sendable (Set<ConfigurationExportSection>) async throws -> ConfigurationExportSource,
        encode: @escaping @Sendable (ConfigurationExportSource, Set<ConfigurationExportSection>) async throws -> FrozenConfigurationExport = { source, sections in
            let worker = Task.detached(priority: .userInitiated) { try ConfigurationExportProjection.make(source: source, sections: sections) }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }) {
        guard !invalidated, !isSaving else { return }
        cancelCapture(); previewIsCurrent = false; notice = .none
        guard !sections.isEmpty else { notice = noticeKey("Choose at least one configuration section."); return }
        let request = UUID(), selected = sections
        captureID = request; isCapturing = true
        captureTask = Task { [weak self] in
            do {
                let source = try await capture(selected)
                try Task.checkCancellation()
                let result = try await encode(source, selected)
                try Task.checkCancellation()
                guard let self, !self.invalidated, self.captureID == request else { return }
                self.snapshot = result; self.previewIsCurrent = true; self.notice = .none
                self.captureID = nil; self.captureTask = nil; self.isCapturing = false
            } catch {
                guard let self, !self.invalidated, self.captureID == request else { return }
                self.captureID = nil; self.captureTask = nil; self.isCapturing = false
                switch error {
                case ConfigurationExportError.snapshotChanged: self.notice = noticeKey("Configuration changed while preparing the preview. Update the preview again.")
                case ConfigurationExportError.unavailableSource: self.notice = noticeKey("A configuration source is unavailable. It cannot be exported as an empty list.")
                case ConfigurationExportError.tooLarge: self.notice = noticeKey("The configuration exceeds the export limits. Choose fewer sections or shorten the definitions.")
                case ConfigurationExportError.invalidDefinition, ConfigurationExportError.invalidReference, ConfigurationExportError.duplicateDefinition:
                    self.notice = noticeKey("A definition or reference is invalid. Review saved definitions and shortcuts before exporting.")
                case is CancellationError: break
                default: self.notice = noticeKey("The configuration preview could not be prepared. Your settings were not changed.")
                }
            }
        }
    }
    private func cancelCapture() {
        captureID = nil; captureTask?.cancel(); captureTask = nil; isCapturing = false
    }
    @discardableResult func beginSave() -> ConfigurationExportSaveAttempt? {
        guard canSave, let snapshot else { return nil }
        let attempt = ConfigurationExportSaveAttempt(snapshot: snapshot); saveAttempt = attempt; notice = .none; return attempt
    }
    @discardableResult func finishSave(_ attemptID: UUID, outcome: ConfigurationExportSaveOutcome) -> Bool {
        guard !invalidated, saveAttempt?.id == attemptID else { return false }
        saveAttempt = nil
        switch outcome {
        case .saved: notice = noticeKey("Configuration definitions saved.")
        case .cancelled: notice = .none
        case .failed: notice = noticeKey("The configuration could not be saved. Your preview is kept; try another location.")
        }
        return true
    }
    func invalidate() {
        invalidated = true; cancelCapture(); snapshot = nil; saveAttempt = nil
        sections = []; previewIsCurrent = false; notice = .none
    }
}

extension SettingsSession {
    func prepareConfigurationExport(in store: WorkbenchModel) {
        guard canBeginSavedItemEditor else { return }
        let presentation = ConfigurationExportPresentation(); configurationExport = presentation
        refreshConfigurationExport(presentation.id, in: store)
    }
    func refreshConfigurationExport(_ presentationID: UUID, in store: WorkbenchModel) {
        guard !store.isShuttingDown, let presentation = configurationExport, presentation.id == presentationID else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "KeyDockReleaseVersion") as? String ?? "development"
        presentation.refresh { sections in try await store.captureConfigurationExport(sections: sections, sourceVersion: version) }
    }
    func closeConfigurationExport(_ presentationID: UUID) {
        guard let presentation = configurationExport, presentation.id == presentationID, !presentation.isSaving else { return }
        invalidateConfigurationExport()
    }
    func configurationExportDidAppear(_ presentationID: UUID) {
        guard let presentation = configurationExport, presentation.id == presentationID else { return }
        presentation.didAppear()
    }
    func configurationExportDidDismiss(_ presentationID: UUID) {
        guard let presentation = configurationExport, presentation.id == presentationID else { return }
        presentation.invalidate(); configurationExport = nil; configurationExportDismissing = false
    }
    func finishConfigurationExportSave(_ presentationID: UUID, attemptID: UUID, outcome: ConfigurationExportSaveOutcome) {
        guard let presentation = configurationExport, presentation.id == presentationID else { return }
        presentation.finishSave(attemptID, outcome: outcome)
    }
    public func invalidateConfigurationExport() {
        if let presentation = configurationExport {
            presentation.invalidate()
            if presentation.appeared { configurationExportDismissing = true }
            else { configurationExport = nil; configurationExportDismissing = false }
        }
    }
}
