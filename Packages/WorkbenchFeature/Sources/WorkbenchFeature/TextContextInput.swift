import Foundation
import ExecutionCore

/// 仅会话内的来源说明；不保存路径、URI、文件句柄或授权，不能编码为持久回执。
public struct TextContextProvenance: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case textFile, pdfText, imageOCR, regionOCR, mcpResource, mcpPrompt }
    public let id: UUID
    public let kind: Kind
    public let displayName: String
    public let capturedAt: Date
    public let bodyRevision: UUID
    public let byteCount: Int
    public let isEdited: Bool
    public let mcpSourceID: UUID?
    static let maximumMetadataBytes = 2_048
    var retainedBytes: Int { displayName.utf8.count + 256 }
    var title: String {
        let type = switch kind {
        case .textFile: L("Text file")
        case .pdfText: L("PDF text")
        case .imageOCR: L("Image OCR")
        case .regionOCR: L("Region OCR")
        case .mcpResource: L("MCP resource")
        case .mcpPrompt: L("MCP prompt")
        }
        return (isEdited ? L("Edited input from") + " · " : "") + type + " · " + displayName
    }
    init(kind: Kind, displayName: String, bodyRevision: UUID, byteCount: Int, mcpSourceID: UUID? = nil) throws {
        guard displayName.utf8.count <= 512, byteCount <= TaskTextLimits.inputBytes, byteCount >= 0 else { throw SessionAdmissionError.capacity }
        id = UUID(); self.kind = kind; self.displayName = displayName; capturedAt = Date()
        self.bodyRevision = bodyRevision; self.byteCount = byteCount; isEdited = false; self.mcpSourceID = mcpSourceID
    }
    private init(original: Self, revision: UUID, byteCount: Int) {
        id = original.id; kind = original.kind; displayName = original.displayName; capturedAt = original.capturedAt
        bodyRevision = revision; self.byteCount = byteCount; isEdited = true; mcpSourceID = original.mcpSourceID
    }
    func edited(revision: UUID, byteCount: Int) -> Self { .init(original: self, revision: revision, byteCount: byteCount) }
}

public struct TextContextInput: Sendable {
    public let text: String
    public let provenance: TextContextProvenance?
    public let revision: UUID
    static var empty: Self { .init(text: "", provenance: nil, revision: UUID()) }
}

extension WorkbenchModel {
    func isRemovedMCPSource(_ provenance: TextContextProvenance?) -> Bool {
        guard let id = provenance?.mcpSourceID else { return false }
        return !configuration.mcpServers.contains { $0.id == id }
    }
}

@MainActor struct AIInputOrigin {
    let source: AIDraftSource
    let application: String?
    let provenance: TextContextProvenance?
    init(_ draft: AIDraftDocument) {
        source = draft.source
        application = draft.sourceTarget.map { TaskTextLimits.prefix($0.applicationName, maximumBytes: 1_024) }
        provenance = draft.inputProvenance
    }
    func apply(to task: inout RunningTaskItem) {
        task.source = source; task.sourceApplication = application; task.inputProvenance = provenance
    }
}

@MainActor final class WeakTextContextSession {
    weak var session: WorkspaceSession?
    init(_ session: WorkspaceSession) { self.session = session }
}

extension WorkbenchModel {
    static var contextSlotBytes: Int { TaskTextLimits.inputBytes + TextContextProvenance.maximumMetadataBytes }
    var retainedContextSlotBytes: Int { contextSessions.values.filter { $0.session != nil }.count * Self.contextSlotBytes }

    func textContextAdmissionBytes(_ session: WorkspaceSession) -> Int? {
        guard !isDesktopReview else { return nil }
        guard !isShuttingDown, !isClearingHistory, !mutatingSession, session.toolsOwner == nil || session.toolsOwner === self else { return nil }
        return contextSessions[session.contextOwnerID]?.session === session ? 0 : Self.contextSlotBytes
    }
    /// 仅在完整任务＋来源槽接纳成功后提交所有权；本步骤不再逐出任何内容。
    func claimTextContext(_ session: WorkspaceSession) -> UUID {
        contextSessions = contextSessions.filter { $0.value.session != nil }
        contextSessions[session.contextOwnerID] = WeakTextContextSession(session); session.toolsOwner = self
        let token = UUID(); session.contextGeneration = token; return token
    }
    private func ownTextContext(_ session: WorkspaceSession) -> Bool {
        guard let bytes = textContextAdmissionBytes(session) else { return false }
        if bytes == 0 { return true }
        guard makeSessionRoom(additionalBytes: bytes) else { admissionNotice(); return false }
        _ = claimTextContext(session); return true
    }
    func beginTextContextImport(_ session: WorkspaceSession) -> UUID? {
        guard ownTextContext(session) else { return nil }
        let token = UUID(); session.contextGeneration = token; return token
    }
    @discardableResult func commitTextContext(_ text: String, kind: TextContextProvenance.Kind, name: String, session: WorkspaceSession, token: UUID, mcpSourceID: UUID? = nil) -> Bool {
        guard !isShuttingDown, !isClearingHistory, session.toolsOwner === self,
              contextSessions[session.contextOwnerID]?.session === session, session.contextGeneration == token else { return false }
        do {
            let revision = UUID(), provenance = try TextContextProvenance(kind: kind, displayName: name, bodyRevision: revision, byteCount: text.utf8.count, mcpSourceID: mcpSourceID)
            session.setToolsInput(.init(text: text, provenance: provenance, revision: revision))
            return true
        } catch { workspaceNoticeMessage = noticeKey("Imported text or its source name is too large. The previous input was kept."); return false }
    }
    public func editToolsInput(_ text: String, session: WorkspaceSession) {
        guard !session.toolsText.utf8.elementsEqual(text.utf8) else { return }
        guard text.utf8.count <= TaskTextLimits.inputBytes else { workspaceNoticeMessage = noticeKey("Input is too long. Split it into smaller parts; nothing was sent."); return }
        guard ownTextContext(session) else { return }
        let revision = UUID(), old = session.toolsInput
        session.contextGeneration = UUID()
        session.setToolsInput(.init(text: text, provenance: old.provenance?.edited(revision: revision, byteCount: text.utf8.count), revision: revision))
    }
    public func clearToolsInput(_ session: WorkspaceSession) {
        guard session.toolsOwner == nil || session.toolsOwner === self else { return }
        session.contextGeneration = UUID(); session.setToolsInput(.empty)
        contextSessions[session.contextOwnerID] = nil; session.toolsOwner = nil
    }
    func clearTextContextInputs() {
        let sessions = contextSessions.values.compactMap(\.session)
        for session in sessions { clearToolsInput(session) }
    }
    public func createToolsDraft(actionID: UUID, session: WorkspaceSession) -> AIDraftDocument? {
        guard !session.toolsText.isEmpty, session.toolsOwner === self else { return nil }
        let snapshot = session.toolsInput
        let draft = createDraft(actionID: actionID, input: snapshot.text, source: snapshot.provenance == nil ? .manual : .importedContext, provenance: snapshot.provenance)
        return ownsDraft(draft) ? draft : nil
    }
}
