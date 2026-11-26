import Carbon
import CryptoKit
import Foundation
import Testing
import AICore
import AgentCore
import AutomationCore
import CommandCore
import ExecutionCore
import MCPAdapters
@testable import MacAdapters
@testable import WorkbenchFeature

@MainActor private final class InstrumentedReviewScope: DesktopReviewRuntimeScope {
    enum WriteFailure { case before, after }
    let base: DesktopReviewScope
    var failure: WriteFailure?
    private(set) var writes = 0
    init(_ base: DesktopReviewScope) { self.base = base }
    var dataDirectory: URL { base.dataDirectory }
    var sessionDirectory: URL { base.sessionDirectory }
    var initialConfigurationData: Data? { base.initialConfigurationData }
    var isCurrent: Bool { base.isCurrent }
    var targetIdentity: TargetIdentity { base.targetIdentity }
    func permits(_ target: TargetIdentity) -> Bool { base.permits(target) }
    func revoke() { base.revoke() }
    func prepareClipboardStorage() throws -> any ClipboardStorageLifetime { try base.prepareClipboardStorage() }
    func writeConfiguration(_ data: Data, to url: URL) throws {
        writes += 1
        if failure == .before { throw CocoaError(.fileWriteUnknown) }
        try base.writeConfiguration(data, to: url)
        if failure == .after { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor private final class ReviewCaptureProbe: ClipboardCaptureSource {
    var reads = 0
    var changeCount: Int { reads += 1; return 1 }
    var availableTypes: [String] { reads += 1; return ["public.utf8-plain-text"] }
    var sourceApplication: String? { reads += 1; return "synthetic.capture.probe" }
    func readText() -> String? { reads += 1; return "Synthetic capture must not be read" }
}

@MainActor private final class ReviewModelFixture {
    let parent: URL
    let scope: InstrumentedReviewScope
    let capture = ReviewCaptureProbe()
    let materialReads = ReviewReadProbe()
    var store: WorkbenchModel?
    var genericCopies = 0, bodyReads = 0, countReads = 0, credentialReads = 0, credentialWrites = 0, legacyWrites = 0, launches = 0
    var copied: [String] = []
    init(initial: Data? = nil) async throws {
        parent = try PrivateFiles.physicalTemporaryDirectory().appendingPathComponent("KeyDock-ReviewModel-" + UUID().uuidString)
        let root = parent.appendingPathComponent("KeyDock-DesktopReview-" + UUID().uuidString)
        let app = parent.appendingPathComponent("SyntheticFixture.app"), binary = app.appendingPathComponent("Contents/MacOS/" + DesktopReviewScope.fixtureExecutableName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contents = Data("Synthetic fixture file; never launched".utf8)
        try contents.write(to: binary)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": DesktopReviewScope.fixtureBundleIdentifier,
            "CFBundleExecutable": DesktopReviewScope.fixtureExecutableName], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let marker: [String: Any] = ["schemaVersion": 1, "rootID": String(root.lastPathComponent.dropFirst("KeyDock-DesktopReview-".count)),
            "reviewBundleIdentifier": DesktopReviewScope.bundleIdentifier, "fixturePID": 42424, "fixtureLaunchTime": 1234.5]
        let markerURL = root.appendingPathComponent("review-session.json")
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        if let initial { try PrivateFiles.write(initial, to: root.appendingPathComponent("Data/configuration.json")) }
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let binding = DesktopReviewBuildBinding(rootParent: parent.path, reviewBundleIdentifier: DesktopReviewScope.bundleIdentifier,
            fixtureBundleIdentifier: DesktopReviewScope.fixtureBundleIdentifier, fixtureAppPath: app.path,
            fixtureBinarySHA256: hash(contents), fixtureInfoSHA256: hash(plist))
        let process = DesktopReviewProcessIdentity(pid: 42424, launchTime: 1234.5, bundleIdentifier: DesktopReviewScope.fixtureBundleIdentifier,
            appPath: app.path, executablePath: binary.path)
        scope = InstrumentedReviewScope(try await DesktopReviewScope.prepare(binding: binding, root: root, probe: { _ in DesktopReviewProcessSnapshot(process) }))
    }
    func open() throws -> WorkbenchModel {
        let materialReads = materialReads
        let model = try WorkbenchModel(dataDirectory: scope.dataDirectory, allowContextCapture: false, desktopReviewScope: scope,
            clipboardWriter: { _ in self.genericCopies += 1 }, clipboardSelectionWriter: { self.copied.append($0) },
            clipboardChangeCount: { self.countReads += 1; return 1 }, clipboardReader: { self.bodyReads += 1; return "Synthetic forbidden body" },
            credentialReader: { _ in self.credentialReads += 1; return "Synthetic forbidden credential" },
            credentialWriter: { _, _ in self.credentialWrites += 1 }, configurationWriter: { _, _ in self.legacyWrites += 1 },
            applicationLauncher: { _ in self.launches += 1; throw DesktopReviewError.unavailable },
            clipboardCaptureSource: capture, taskMaterialReadObserver: { _, _ in materialReads.read() }, languageApplier: { _ in })
        store = model; return model
    }
    func cleanup() async {
        await store?.shutdownAndWait(); store = nil
        UserDefaults.standard.removePersistentDomain(forName: ClipboardPanelPreferences.desktopReviewSuiteName(scope.dataDirectory))
        try? FileManager.default.removeItem(at: parent)
    }
}

@MainActor private func withReviewModel(initial: Data? = nil, _ body: (ReviewModelFixture) async throws -> Void) async throws {
    let f = try await ReviewModelFixture(initial: initial)
    do { try await body(f); await f.cleanup() } catch { await f.cleanup(); throw error }
}

private actor ReviewTransportProbe: MCPHTTPTransporting {
    private(set) var sends = 0
    func send(configuration: MCPServerConfiguration, method: String, params: [String: JSONValue], id: Int?, sessionID: String?) async throws -> MCPHTTPReply {
        sends += 1; throw MCPClientError.transport
    }
}
private final class ReviewReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func read() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite(.serialized) @MainActor struct DesktopReviewPolicyTests {
    @Test func canonicalConfigurationHasNoImplicitAgentOrLauncherAndRoundTrips() throws {
        var c = try DesktopReviewConfigurationCodec.load(nil)
        #expect(c.launcherShortcut == nil && c.agents.isEmpty && c.aiActions.isEmpty && c.commandShortcuts.isEmpty)
        c.language = "zh-Hans"; c.appearance = "dark"; c.commandShortcuts["utility.clipboard"] = .init(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
        let data = try DesktopReviewConfigurationCodec.encode(c)
        let restored = try DesktopReviewConfigurationCodec.load(data)
        #expect(restored.language == "zh-Hans" && restored.appearance == "dark" && restored.commandShortcuts == c.commandShortcuts)
        #expect(try DesktopReviewConfigurationCodec.encode(DesktopReviewConfigurationCodec.baseline()) == Data("{\"appearance\":\"system\",\"clipboardShortcut\":null,\"formatVersion\":1,\"language\":\"system\"}".utf8))
    }
    @Test(arguments: ["", "{}", "null", "[]", "{\"appearance\":\"system\",\"clipboardShortcut\":null,\"formatVersion\":2,\"language\":\"system\"}",
        "{\"appearance\":\"system\",\"clipboardShortcut\":null,\"formatVersion\":1,\"language\":\"system\",\"unknown\":true}",
        "{\"appearance\":\"system\",\"clipboardShortcut\":null,\"formatVersion\":1,\"formatVersion\":1,\"language\":\"system\"}",
        "{\"appearance\":\"system\",\"clipboardShortcut\":{\"keyCode\":9,\"modifiers\":256,\"extra\":0},\"formatVersion\":1,\"language\":\"system\"}"])
    func malformedUnknownDuplicateOrFutureConfigurationIsRejected(_ raw: String) throws {
        #expect(throws: (any Error).self) { try DesktopReviewConfigurationCodec.load(Data(raw.utf8)) }
    }
    @Test(arguments: ["launcher", "endpoint", "model", "modelSettings", "modelRevision", "http", "capture", "activity", "material", "agent", "command", "action", "workflow", "snippet", "search", "mcp", "favorite", "alias", "recent", "exclusion", "parameter", "otherShortcut", "invalidHotkey", "language", "appearance"])
    func forbiddenConfigurationNeverEncodes(_ field: String) throws {
        var c = DesktopReviewConfigurationCodec.baseline()
        switch field {
        case "launcher": c.launcherShortcut = .init()
        case "endpoint": c.endpoint = "https://synthetic.invalid/chat/completions"
        case "model": c.model = "synthetic"
        case "modelSettings": c.aiModelSettings.defaults.reasoning = .high
        case "modelRevision": c.aiSettingsRevision = UUID()
        case "http": c.localHTTP = true
        case "capture": c.clipboardEnabled = true
        case "activity": c.activityEnabled = true
        case "material": c.taskMaterialRetentionEnabled = true
        case "agent": c.agents = [AgentDefinition()]
        case "command": c.savedCommands = [.init(name: "Synthetic", executable: "/usr/bin/true", workingDirectory: "/tmp")]
        case "action": c.aiActions = [.init(name: "Synthetic", prompt: "Synthetic")]
        case "workflow": c.workflows = [.init(name: "Synthetic", steps: [])]
        case "snippet": c.snippets = [try .init(name: "Synthetic", text: "Synthetic")]
        case "search": c.searchFolders = [.init(id: UUID(), name: "Synthetic", bookmark: Data())]
        case "mcp": c.mcpServers = [.init(name: "Synthetic", endpoint: URL(string: "https://synthetic.invalid/mcp")!)]
        case "favorite": c.preferences.favorites = ["synthetic"]
        case "alias": c.preferences.aliases = ["synthetic": "synthetic"]
        case "recent": c.preferences.recent = ["synthetic": Date()]
        case "exclusion": c.clipboardExclusions = []
        case "parameter": c.tokenLimitParameter = "max_tokens"
        case "otherShortcut": c.commandShortcuts["utility.capture"] = .init()
        case "invalidHotkey": c.commandShortcuts["utility.clipboard"] = .init(keyCode: 128, modifiers: UInt32(cmdKey))
        case "language": c.language = "invalid"
        default: c.appearance = "invalid"
        }
        #expect(throws: DesktopReviewError.invalidScope) { try DesktopReviewConfigurationCodec.encode(c) }
    }
    @Test func initializationRequiresExplicitDirectoryAndCaptureDisabled() async throws {
        try await withReviewModel { f in
            #expect(throws: DesktopReviewError.invalidScope) { try WorkbenchModel(desktopReviewScope: f.scope) }
            #expect(throws: DesktopReviewError.invalidScope) { try WorkbenchModel(allowContextCapture: false, desktopReviewScope: f.scope) }
            let outside = f.parent.appendingPathComponent("must-not-be-created")
            #expect(throws: DesktopReviewError.invalidScope) { try WorkbenchModel(dataDirectory: outside, allowContextCapture: false, desktopReviewScope: f.scope) }
            #expect(!FileManager.default.fileExists(atPath: outside.path) && f.scope.writes == 0)
        }
    }
    @Test func invalidInitialConfigurationIsPreservedBeforeStoreAdmission() async throws {
        let raw = Data("{\"endpoint\":\"synthetic forbidden configuration\"}".utf8)
        try await withReviewModel(initial: raw) { f in
            #expect(throws: (any Error).self) { try f.open() }
            let preserved = try Data(contentsOf: f.scope.dataDirectory.appendingPathComponent("configuration.json"))
            #expect(preserved == raw)
            #expect(!FileManager.default.fileExists(atPath: f.scope.dataDirectory.appendingPathComponent("clipboard.sqlite").path))
            #expect(f.scope.writes == 0 && f.legacyWrites == 0)
        }
    }
    @Test func startupAndDirectRestorationIgnorePersistentAuxiliaryArchives() async throws {
        try await withReviewModel { f in
            let old = try InvocationStore(directory: f.scope.dataDirectory.appendingPathComponent("invocations"))
            let id = UUID(); try await old.begin(id: id, name: "Synthetic previous run")
            try await old.finish(id: id, result: .init(state: .failed, message: "synthetic.previous"))
            let row = try #require(await old.list().first)
            let protected = f.scope.dataDirectory.appendingPathComponent("application-actions.json")
            try PrivateFiles.write(Data("Synthetic on-disk file is not the injected initial snapshot".utf8), to: protected)
            let bytes = try Data(contentsOf: protected)
            let store = try f.open()
            store.restoreReceipt(row); store.restoreAIReceipt(row); store.restoreHistorySnapshot(cli: [row], ai: [], generation: store.historyGeneration)
            store.startApplicationUpdates(); store.refreshApplications(); store.startReceiptMaintenance(); store.scheduleTaskMaterialMaintenance()
            await store.refreshTaskMaterialIndex()
            #expect(store.tasks.isEmpty && store.drafts.isEmpty && store.schedules.isEmpty)
            #expect(store.legacyApplicationActions == nil && store.configurationDirectoryIdentity == nil && store.desktopWorkspaceStore == nil)
            #expect(store.receiptMaintenanceTask == nil && store.taskMaterialMaintenanceTask == nil && store.scheduleTimer == nil)
            #expect(await store.invocationStore.list().isEmpty && store.catalog.map(\.id) == ["utility.clipboard"])
            let previous = await old.list()
            #expect(try Data(contentsOf: protected) == bytes && previous.first?.state == .failed)
        }
    }
    @Test func onlyExplicitHistoryCopyUsesTheNarrowWriter() async throws {
        try await withReviewModel { f in
            let store = try f.open()
            try store.copyClipboardSelection("Synthetic selected history")
            #expect(f.copied == ["Synthetic selected history"])
            #expect(throws: DesktopReviewError.unavailable) { try store.copyAuthorizedText("Synthetic ordinary output") }
            #expect(throws: DesktopReviewError.unavailable) { try store.copyAuthorizedText("Synthetic model copy", caller: .agent, historySelection: true) }
            f.scope.revoke()
            #expect(throws: DesktopReviewError.unavailable) { try store.copyClipboardSelection("Synthetic late copy") }
            #expect(f.genericCopies == 0 && f.bodyReads == 0 && f.countReads == 0 && f.capture.reads == 0 && f.copied.count == 1)
        }
    }
    @Test func allowedSettingsUseScopeAndInvalidCandidatesReachNeitherOSNorLegacyWriter() async throws {
        try await withReviewModel { f in
            let store = try f.open(); var registrations = 0
            store.onShortcutConfigurationChanged = { _ in registrations += 1 }
            #expect(store.setLanguage("en") && store.setAppearance("dark"))
            let binding = HotkeyBinding(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
            #expect(store.setShortcut(binding, for: "utility.clipboard"))
            let writes = f.scope.writes
            var next = store.configuration; next.endpoint = "https://synthetic.invalid/chat/completions"
            #expect(!store.commitShortcutConfiguration(next))
            let invalid = store.setShortcut(HotkeyBinding(keyCode: 9, modifiers: 0), for: "utility.clipboard")
            #expect(!invalid)
            #expect(!store.setShortcut(binding, for: "utility.capture") && !store.setLauncherShortcut(nil))
            #expect(!store.saveAPIConfiguration(endpoint: "https://synthetic.invalid/chat/completions", modelName: "synthetic", localHTTP: false, tokenParameter: "max_tokens", apiKey: ""))
            #expect(f.scope.writes == writes && registrations == 1 && f.legacyWrites == 0 && f.credentialReads == 0 && f.credentialWrites == 0)
            let restored = try DesktopReviewConfigurationCodec.load(Data(contentsOf: f.scope.dataDirectory.appendingPathComponent("configuration.json")))
            #expect(restored.language == "en" && restored.appearance == "dark" && restored.commandShortcuts["utility.clipboard"] == binding)
        }
    }
    @Test(arguments: [false, true])
    func unconfirmedSettingsDisableReviewWithoutPathBasedCompensation(_ afterWrite: Bool) async throws {
        try await withReviewModel { f in
            let store = try f.open(); var registered: [HotkeyBinding?] = []
            store.onShortcutConfigurationChanged = { registered.append($0.commandShortcuts["utility.clipboard"]) }
            #expect(store.setLanguage("en"))
            f.scope.failure = afterWrite ? .after : .before
            let binding = HotkeyBinding(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
            #expect(!store.setShortcut(binding, for: "utility.clipboard"))
            #expect(registered == [binding, nil] && store.configuration.commandShortcuts.isEmpty && store.configuration.language == "en")
            #expect(!store.desktopReviewAvailable && !f.scope.isCurrent && !store.settingsNotice.isEmpty && f.legacyWrites == 0)
            let raw = try Data(contentsOf: f.scope.dataDirectory.appendingPathComponent("configuration.json"))
            #expect(try DesktopReviewConfigurationCodec.load(raw).commandShortcuts["utility.clipboard"] == (afterWrite ? binding : nil))
            let protected = f.parent.appendingPathComponent("protected-synthetic-settings")
            try Data("preserve".utf8).write(to: protected)
            #expect(throws: DesktopReviewError.unavailable) { try store.restoreConfiguration(.absent, at: protected) }
            #expect(try Data(contentsOf: protected) == Data("preserve".utf8))
            let before = f.scope.writes
            #expect(!store.setLanguage("zh-Hans") && registered.count == 2 && f.scope.writes == before)
        }
    }
    @Test func revokedScopeCannotRegisterOrPersistNewSettings() async throws {
        try await withReviewModel { f in
            let store = try f.open(); var registrations = 0
            store.onShortcutConfigurationChanged = { _ in registrations += 1 }
            f.scope.revoke()
            let accepted = store.setShortcut(HotkeyBinding(), for: "utility.clipboard")
            #expect(!accepted)
            #expect(registrations == 0 && f.scope.writes == 0 && f.legacyWrites == 0)
        }
    }
    @Test func pollutedConfigurationStillDispatchesNoHTTPCLIOrApplication() async throws {
        let server = try StoreSSEServer(); defer { server.stop() }
        try await withReviewModel { f in
            let store = try f.open(), marker = f.parent.appendingPathComponent("command-must-not-run")
            let command = SavedCommand(name: "Synthetic forbidden CLI", executable: "/usr/bin/touch", arguments: [marker.path], workingDirectory: f.parent.path)
            let action = AIActionPreset(name: "Synthetic forbidden AI", prompt: "Synthetic prompt")
            store.configuration.savedCommands = [command]; store.configuration.aiActions = [action]
            store.configuration.endpoint = server.endpoint("stream"); store.configuration.model = "synthetic"; store.configuration.localHTTP = true
            #expect(throws: DesktopReviewError.unavailable) { try store.provider() }
            #expect(store.runCommand(command) == nil && store.runAgent(AgentDefinition(), input: "Synthetic input") == nil)
            #expect(store.runWorkflow(.init(name: "Synthetic workflow", steps: [.init(operation: .savedCommand(command.id))]), input: "Synthetic") == nil)
            let draft = store.createDraft(actionID: action.id, input: "Synthetic input")
            #expect(draft.isDiscarded && store.runAI(action: action, draft: draft) == nil && !store.reserveExecution(UUID()))
            store.execute(.init(id: "synthetic.app", title: "Synthetic app", kind: .application, payload: f.parent.path))
            store.save()
            #expect(!store.isContributionEnabled(BuiltinContributionID.commands) && !store.isContributionEnabled(BuiltinContributionID.files))
            #expect(store.tasks.isEmpty && store.taskHandles.isEmpty && f.launches == 0 && f.scope.writes == 0)
            #expect(!FileManager.default.fileExists(atPath: marker.path) && f.credentialReads == 0 && f.genericCopies == 0)
            #expect(try await server.stats()["post_requests"] == 0)
        }
    }
    @Test func existingMCPClientAndStdioDefinitionsDoNotDispatch() async throws {
        try await withReviewModel { f in
            let store = try f.open(), transport = ReviewTransportProbe()
            let source = MCPServerConfiguration(name: "Synthetic source", endpoint: URL(string: "https://synthetic.invalid/mcp")!, enabled: true)
            let client = try MCPHTTPClient(configuration: source, transport: transport)
            store.configuration.mcpServers = [source]; store.mcpClients[source.id] = client
            #expect(throws: DesktopReviewError.unavailable) { try store.makeMCPClient(source) }
            await #expect(throws: DesktopReviewError.unavailable) { try await store.discoverMCP(client) }
            let session = WorkspaceSession()
            store.connectMCP(source.id); store.browseMCPResources(source.id); store.browseMCPPrompts(source.id)
            store.readMCPResource(source.id, uri: "synthetic://owned/text", session: session)
            store.readMCPPrompt(source.id, name: "synthetic", arguments: "{}", session: session)
            let marker = f.parent.appendingPathComponent("stdio-must-not-run")
            let stdio = MCPServerConfiguration(name: "Synthetic stdio", stdio: .init(executable: "/usr/bin/touch", arguments: [marker.path], workingDirectory: f.parent.path), enabled: true)
            #expect(throws: DesktopReviewError.unavailable) { try store.makeMCPClient(stdio) }
            #expect(await transport.sends == 0 && store.mcpConnectionTask == nil && store.configurationOperations.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: marker.path) && store.contextSessions.isEmpty)
        }
    }
    @Test func importSchedulingAndUsageReadersStayInactive() async throws {
        try await withReviewModel { f in
            let store = try f.open(), session = WorkspaceSession(), reads = ReviewReadProbe()
            let file = f.parent.appendingPathComponent("synthetic.txt"); try Data("Synthetic import must not be read".utf8).write(to: file)
            store.importDocument(file, session: session); store.addSearchFolder(f.parent)
            store.startSchedules(); await store.tickSchedules()
            await store.refreshAIUsageAnalysis(days: 7, reader: { _, _ in reads.read(); throw DesktopReviewError.unavailable })
            await store.loadRestoredAIUsage(UUID(), interrupted: true, reader: { reads.read(); return .init(data: nil, problem: nil, revision: 0) }).value
            await store.loadRestoredWorkflowUsage(UUID(), reader: { reads.read(); throw DesktopReviewError.unavailable }).value
            #expect(store.beginScheduleMutation() == nil && store.beginMCPSettingsMutation() == nil)
            #expect(!store.setTaskMaterialRetention(true) && !store.setClipboardRecording(true))
            await store.setActivityTracking(true)
            #expect(reads.count == 0 && store.tasks.isEmpty && store.taskHandles.isEmpty && store.contextSessions.isEmpty)
            #expect(store.scheduleTimer == nil && f.scope.writes == 0 && f.legacyWrites == 0 && !store.configuration.activityEnabled)
        }
    }
    @Test func usageClearAndMaterialPresentationDoNotReadOrDeleteOwnedAuxiliaryData() async throws {
        try await withReviewModel { f in
            let store = try f.open(), id = UUID()
            let usage = f.scope.sessionDirectory.appendingPathComponent("usage/" + id.uuidString + ".json")
            let bytes = Data("Synthetic owned usage sentinel".utf8)
            try PrivateFiles.write(bytes, to: usage)
            await store.clearAIUsageHistory()
            #expect(try Data(contentsOf: usage) == bytes)
            let definition = RunDefinitionReference(kind: .savedCommand, definitionID: UUID(), fingerprint: String(repeating: "0", count: 64))
            let begun = try await store.invocationStore.begin(id: id, name: "Synthetic owner", runDefinition: definition)
            try await store.invocationStore.finish(id: id, result: .init(state: .succeeded), expectedRunStamp: begun.runStamp)
            let row = try #require(await store.invocationStore.list().first)
            let birth = try #require(row.runAttempt?.recordIdentity)
            let key = TaskMaterialKey(receiptStore: .cli, invocationID: id, receiptRecordIdentity: birth)
            store.taskMaterialFence.setEnabled(true)
            let check = try await store.taskMaterialStore.prepareWrite(key, expected: nil)
            _ = try await store.taskMaterialStore.save(.init(visibleResult: "Synthetic material must not be read by the Review UI",
                resultKind: .visibleResult, resultWasPartial: false, resultCapturedAt: Date().timeIntervalSince1970), using: check)
            let before = f.materialReads.count
            let presentation = TaskMaterialPresentation(key: key, mode: .view, title: "Synthetic", store: store)
            await presentation.refresh(in: store)?.value
            await #expect(throws: DesktopReviewError.unavailable) { try await store.reviewAttempt(.init(store: .cli, invocationID: id)) }
            #expect(presentation.phase == .unavailable && presentation.buffer == nil && f.materialReads.count == before)
        }
    }
    @Test func invalidRootBoundPanelPreferencesAreNotSilentlyRepaired() async throws {
        try await withReviewModel { f in
            let name = ClipboardPanelPreferences.desktopReviewSuiteName(f.scope.dataDirectory)
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.set("Synthetic unknown preference", forKey: "clipboard.panel.primaryAction")
            #expect(throws: DesktopReviewError.invalidScope) { try f.open() }
            #expect(defaults.string(forKey: "clipboard.panel.primaryAction") == "Synthetic unknown preference")
            #expect(f.scope.writes == 0 && f.legacyWrites == 0)
        }
    }
}
