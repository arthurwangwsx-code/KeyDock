import Foundation
import AutomationCore
import AppKit

extension WorkbenchModel {
    func recordDirectActivity(commandID:String,category:ActivityCategory,outcome:ActivityOutcome,startedAt:Date = Date()) {
        guard !isDesktopReview else { return }
        guard configuration.activityEnabled,!activityChanging,!activityIsClearing,!isShuttingDown else { return }
        let event = ActivityEvent(commandID:"keydock."+fingerprint(commandID),category:category,outcome:outcome,duration:min(604_800,max(0,Date().timeIntervalSince(startedAt))),date:startedAt)
        Task { [weak self] in
            guard let self else { return }
            do { try await activityLedger.record(event) }
            catch { workspaceNoticeMessage = noticeKey("Usage statistics could not be saved") }
        }
    }

    func registerActivity(_ id: UUID, commandID: String, category: ActivityCategory) {
        guard !isDesktopReview else { return }
        guard configuration.activityEnabled, !activityChanging else { return }
        taskActivity[id] = ("keydock."+fingerprint(commandID),category)
    }
    func completeActivity(_ id: UUID, state: TaskStatus) {
        guard let (command,category) = taskActivity.removeValue(forKey:id), configuration.activityEnabled,
              let task = tasks.first(where:{$0.id == id}) else { return }
        let outcome: ActivityOutcome
        switch state {
        case .completed,.draftReady: outcome = .succeeded
        case .cancelled: outcome = .cancelled
        case .failed,.timedOut: outcome = .failed
        case .interrupted: outcome = .interrupted
        default: outcome = .unknown
        }
        let event = ActivityEvent(id:id,commandID:command,category:category,outcome:outcome,duration:min(604_800,max(0,Date().timeIntervalSince(task.startedAt))))
        Task { [weak self] in
            guard let self else { return }
            do { try await activityLedger.record(event) }
            catch { workspaceNoticeMessage = noticeKey("Usage statistics could not be saved") }
        }
    }
    public func setActivityTracking(_ enabled: Bool) async {
        guard !isDesktopReview else { desktopReviewUnavailable(); return }
        guard !isShuttingDown, !activityChanging else { return }
        activityChanging = true; defer { activityChanging = false }
        if !enabled { configuration.activityEnabled = false; taskActivity.removeAll(); try? await activityLedger.setEnabled(false) }
        var next = configuration; next.activityEnabled = enabled
        guard commitSettingsConfiguration(next) else {
            try? await activityLedger.setEnabled(false); configuration.activityEnabled = false; taskActivity.removeAll()
            workspaceNoticeMessage = noticeKey("Statistics are paused for this session. Settings could not be saved."); return
        }
        do { try await activityLedger.setEnabled(enabled) }
        catch { configuration.activityEnabled = false; workspaceNoticeMessage = noticeKey("Usage statistics could not be saved") }
    }
    public func refreshActivity(days: Int) async {
        guard !isDesktopReview else { return }
        guard !isShuttingDown, !activityIsClearing else { return }
        activityGeneration &+= 1; let generation = activityGeneration
        let now = Date()
        do {
            let report = try await activityLedger.report(from:now.addingTimeInterval(-Double(min(30,max(1,days)))*86_400),to:now,now:now)
            guard !isShuttingDown, !activityIsClearing, activityGeneration == generation else { return }; activityReport = report
        }
        catch { workspaceNoticeMessage = noticeKey("Usage statistics could not be read") }
    }
    public func clearActivity() async {
        guard !isDesktopReview else { return }
        guard !activityIsClearing, !isShuttingDown else { return }
        activityGeneration &+= 1; activityIsClearing = true; activityReport = nil
        defer { activityIsClearing = false }
        do { try await activityLedger.clear() }
        catch { workspaceNoticeMessage = noticeKey("Usage statistics could not be cleared") }
    }
    public func summarizeActivity() {
        guard let report = activityReport, report.totalCount > 0 else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let input = String(decoding:try encoder.encode(report),as:UTF8.self)
            let draft = AIDraftDocument(input:input,actionID:nil,target:nil,source:.manual)
            guard registerDraft(draft) else { return }
            let language = AIResponseLanguage(preference: configuration.language)
            let action = AIActionPreset(name:L("Usage summary"),prompt:"Analyze only this aggregate KeyDock usage report. State the time range, partial coverage and evidence counts. Missing events are unknown. Suggest useful shortcuts or workflows without inventing activity or executing anything. Identify opaque command IDs only by their supplied IDs. " + language.finalResponseInstruction)
            if let id = runAI(action:action,draft:draft) { onOpenWorkspace?(.tasks(id)) }
        } catch { workspaceNoticeMessage = noticeKey("Usage statistics could not be read") }
    }
    func activityLabel(_ id: String) -> String {
        catalog.first(where:{"keydock."+fingerprint($0.id) == id})?.title ?? id
    }
}
