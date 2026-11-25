import Foundation
import CommandCore
import MacAdapters
import ExecutionCore

extension WorkbenchModel {
    @discardableResult public func saveSnippet(id: UUID? = nil,name: String,text: String) -> Bool {
        do {
            let snippet = try SnippetDefinition(id:id ?? UUID(),name:name,text:text)
            var next = configuration
            if let index = next.snippets.firstIndex(where:{$0.id == snippet.id}) { next.snippets[index] = snippet }
            else { guard next.snippets.count < 200 else { throw SnippetValidationError.textTooLong }; next.snippets.append(snippet) }
            guard try JSONEncoder().encode(next).count <= 4*1_048_576 else { throw SnippetValidationError.textTooLong }
            return commitSettingsConfiguration(next)
        } catch { workspaceNoticeMessage = noticeKey("Snippet could not be saved. Check its name and text size."); return false }
    }
    public func copySnippet(_ id: UUID, caller: ExecutionCaller = .user) {
        guard let snippet = configuration.snippets.first(where:{$0.id == id}) else { return }
        do { try copyAuthorizedText(snippet.text,caller:caller); recordDirectActivity(commandID:"snippet."+id.uuidString,category:.utility,outcome:.succeeded) } catch { workspaceNoticeMessage = noticeKey("Text could not be copied") }
    }
    public func removeSnippet(_ id: UUID) {
        var next = configuration; next.snippets.removeAll{$0.id == id}; _ = commitSettingsConfiguration(next)
    }
    public func importDocument(_ url: URL, session: WorkspaceSession) {
        runContextOperation(resource:url.path,operation:.importContext,session:session,work:{
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try await DocumentContextService.read(url)
        },origin:{ result in
            let kind: TextContextProvenance.Kind = switch result.extraction { case .text: .textFile; case .pdfText: .pdfText; case .imageOCR: .imageOCR }
            return (kind,result.displayName)
        })
    }
    public func captureRegion(session: WorkspaceSession) {
        guard allowContextCapture else { workspaceNoticeMessage = noticeKey("Context capture is disabled in isolated smoke mode"); return }
        runContextOperation(resource:"user-selected-screen-region",operation:.captureScreen,session:session,work:{ try await DocumentContextService.captureRegion() },origin:{ _ in
            (.regionOCR,L("Selected screen region"))
        })
    }
    private func runContextOperation(resource:String,operation:HostOperation,session:WorkspaceSession,work:@escaping @Sendable () async throws -> DocumentText,origin:@escaping @MainActor (DocumentText)->(TextContextProvenance.Kind,String)) {
        let id = UUID()
        do {
            let authorization = try authorizeHostAction(id:"context.import",operation:operation,resource:resource,availableContext:[.explicitInput],invocation:id)
            guard let bytes = textContextAdmissionBytes(session), reserveExecution(id,additionalBytes:bytes) else { return }
            let token = claimTextContext(session)
            if operation == .captureScreen { onDismiss?(true) }
            tasks.insert(RunningTaskItem(id:id,title:L("Text import"),state:.running,titleKey:"Text import"),at:0); tasks[0].receiptIsAI = true
            aiTaskIDs.insert(id); registerActivity(id,commandID:"context.import",category:.utility)
            taskHandles[id] = Task { [weak self, weak session] in
                guard let self else { return }
                var started = false
                do {
                    try await beginAIReceipt(id:id,kind:.context,authorization:authorization); started = true; try Task.checkCancellation()
                    let result = try await work(); try Task.checkCancellation()
                    guard !isShuttingDown else { throw CancellationError() }
                    _ = appendOutput(id,text:result.text)
                    if let session { let (kind,name) = origin(result); commitTextContext(result.text,kind:kind,name:name,session:session,token:token) }
                    updateTask(id,state:.completed,finished:true)
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError || (error as? DocumentContextError) == .cancelled
                    updateTask(id,state:cancelled ? .cancelled:.failed,finished:true)
                    if !cancelled { workspaceNoticeMessage = (error as? DocumentContextError) == .screenPermissionRequired ? noticeKey("Screen Recording permission is required. Enable it in macOS Settings, then try again.") : noticeKey("Text could not be imported. Use a readable text, PDF or single image within the size limit.") }
                }
                if started { await finishAIReceipt(id) }; finishExecutionReservation(id)
            }
        } catch { workspaceNoticeMessage = noticeKey("Text could not be imported. Use a readable text, PDF or single image within the size limit.") }
    }
}
