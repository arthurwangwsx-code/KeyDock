import Foundation
import Combine

struct SettingsSummarySaveAttempt: Identifiable, Sendable {
    let id = UUID()
    let snapshot: FrozenSettingsSummary
}
enum SettingsSummarySaveOutcome { case saved, cancelled, failed }

@MainActor final class SettingsSummaryPresentation: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var sections: Set<SettingsSummarySection>
    @Published private(set) var snapshot: FrozenSettingsSummary?
    @Published private(set) var saveAttempt: SettingsSummarySaveAttempt?
    @Published private(set) var notice: LocalizedNotice = .none
    @Published private(set) var invalidated = false
    private(set) var appeared = false
    var isSaving: Bool { saveAttempt != nil }
    var needsPreview: Bool { snapshot?.sections != sections }
    var canSave: Bool { !invalidated && !isSaving && !sections.isEmpty && !needsPreview && snapshot != nil }
    init(snapshot: FrozenSettingsSummary) { self.snapshot = snapshot; sections = snapshot.sections }
    func didAppear() { if !invalidated { appeared = true } }
    func setSection(_ section: SettingsSummarySection, selected: Bool) {
        guard !invalidated, !isSaving else { return }
        if selected { sections.insert(section) } else { sections.remove(section) }
        notice = .none
    }
    @discardableResult func refresh(configuration: AppConfiguration, clipboard: ClipboardSummaryPreferences) -> Bool {
        guard !invalidated, !isSaving else { return false }
        do { snapshot = try SettingsSummaryProjection.make(configuration: configuration, clipboard: clipboard, sections: sections); notice = .none; return true }
        catch SettingsSummaryError.noSections { notice = noticeKey("Choose at least one summary section."); return false }
        catch { notice = noticeKey("The settings summary could not be prepared. Your settings were not changed."); return false }
    }
    @discardableResult func beginSave() -> SettingsSummarySaveAttempt? {
        guard canSave, let snapshot else { return nil }
        let attempt = SettingsSummarySaveAttempt(snapshot: snapshot); saveAttempt = attempt; notice = .none; return attempt
    }
    @discardableResult func finishSave(_ attemptID: UUID, outcome: SettingsSummarySaveOutcome) -> Bool {
        guard !invalidated, saveAttempt?.id == attemptID else { return false }
        saveAttempt = nil
        switch outcome {
        case .saved: notice = noticeKey("Settings summary saved.")
        case .cancelled: notice = .none
        case .failed: notice = noticeKey("The settings summary could not be saved. Your preview is kept; try another location.")
        }
        return true
    }
    func invalidate() { invalidated = true; snapshot = nil; saveAttempt = nil; sections = []; notice = .none }
}

extension SettingsSession {
    func prepareSettingsSummary(in store: WorkbenchModel) {
        guard canBeginSavedItemEditor else { return }
        do {
            let snapshot = try SettingsSummaryProjection.make(configuration: store.configuration,
                clipboard: .init(primaryAction: store.clipboardPreferences.primaryAction, separator: store.clipboardPreferences.separator), sections: [.basicPreferences])
            settingsSummaryExport = SettingsSummaryPresentation(snapshot: snapshot)
        } catch { store.settingsNoticeMessage = noticeKey("The settings summary could not be prepared. Your settings were not changed.") }
    }
    func refreshSettingsSummary(_ presentationID: UUID, in store: WorkbenchModel) {
        guard !store.isShuttingDown, let presentation = settingsSummaryExport, presentation.id == presentationID else { return }
        presentation.refresh(configuration: store.configuration,
            clipboard: .init(primaryAction: store.clipboardPreferences.primaryAction, separator: store.clipboardPreferences.separator))
    }
    func closeSettingsSummary(_ presentationID: UUID) {
        guard let presentation = settingsSummaryExport, presentation.id == presentationID, !presentation.isSaving else { return }
        // 等待sheet真正收起后释放编辑门禁，避免关闭动画期间叠开另一业务sheet。
        invalidateSettingsSummaryExport()
    }
    func settingsSummaryDidAppear(_ presentationID: UUID) {
        guard let presentation = settingsSummaryExport, presentation.id == presentationID else { return }
        presentation.didAppear()
    }
    func settingsSummaryDidDismiss(_ presentationID: UUID) {
        guard let presentation = settingsSummaryExport, presentation.id == presentationID else { return }
        presentation.invalidate(); settingsSummaryExport = nil; settingsSummaryDismissing = false
    }
    func finishSettingsSummarySave(_ presentationID: UUID, attemptID: UUID, outcome: SettingsSummarySaveOutcome) {
        guard let presentation = settingsSummaryExport, presentation.id == presentationID else { return }
        presentation.finishSave(attemptID, outcome: outcome)
    }
    public func invalidateSettingsSummaryExport() {
        if let presentation = settingsSummaryExport {
            presentation.invalidate()
            if presentation.appeared { settingsSummaryDismissing = true }
            else { settingsSummaryExport = nil; settingsSummaryDismissing = false }
        }
    }
}
