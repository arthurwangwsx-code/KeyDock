import Foundation
import Testing
import MacAdapters
@testable import WorkbenchFeature

@Suite(.serialized) @MainActor struct ClipboardCopyFailureTests {
    @Test func throwingWriterReachesThePanelCallerAndLegacyCallerReportsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-CopyFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var writes = 0
        let store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: false,
            clipboardWriter: { _ in writes += 1; throw CocoaError(.fileWriteUnknown) }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
            credentialReader: { _ in nil }, credentialWriter: { _, _ in }, applicationCatalog: ApplicationCatalog(roots: []), languageApplier: { _ in })
        #expect(throws: CocoaError.self) { try store.copyClipboardSelection("Synthetic selection") }
        #expect(writes == 1)
        store.copyClipboardText("Synthetic selection")
        #expect(writes == 2 && !store.workspaceNotice.isEmpty)
        await store.shutdownAndWait()
    }
}
