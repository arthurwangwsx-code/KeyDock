import Foundation
import Testing
import MacAdapters
import KeyDockUI
@testable import WorkbenchFeature

private enum SyntheticPersistenceFailure: Error { case read, credentialWrite, configurationWrite }
enum APIWriteFault: CaseIterable { case before, after }
enum APIRollbackFault: CaseIterable { case credential, configuration }

/// 只有合成内存凭据；测试永远不调用系统 CredentialStore。
@MainActor private final class MemoryCredentials {
    var values: [String: String]
    var reads = 0
    var writes: [(key: String, account: String)] = []
    var readFailures: Set<Int> = []
    var failBeforeWrite: Set<Int> = []
    var failAfterWrite: Set<Int> = []
    init(_ values: [String: String]) { self.values = values }
    func read(_ account: String) throws -> String? {
        reads += 1
        if readFailures.contains(reads) { throw SyntheticPersistenceFailure.read }
        return values[account]
    }
    func write(_ key: String, account: String) throws {
        writes.append((key, account))
        if failBeforeWrite.contains(writes.count) { throw SyntheticPersistenceFailure.credentialWrite }
        if key.isEmpty { values[account] = nil } else { values[account] = key }
        if failAfterWrite.contains(writes.count) { throw SyntheticPersistenceFailure.credentialWrite }
    }
}

@MainActor private final class APIAtomicityFixture {
    static let endpoint = "https://synthetic.invalid/chat/completions"
    let directory: URL
    let store: WorkbenchModel
    let original: AppConfiguration
    let originalBytes: Data?
    var configurationURL: URL { directory.appendingPathComponent("configuration.json") }
    private let languageKey: String
    private let previousLanguage: Any?

    init(credentials: MemoryCredentials, existingFile: Bool = true,
         writer: @escaping @MainActor (Data, URL) throws -> Void = { try PrivateFiles.write($0, to: $1) }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-API-Atomicity-" + UUID().uuidString, isDirectory: true)
        languageKey = (Bundle.main.object(forInfoDictionaryKey: "KeyDockSafeSmoke") as? Bool == true) ? "KeyDock.Smoke.Language" : "KeyDock.Language"
        previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var configuration = AppConfiguration()
        configuration.endpoint = Self.endpoint; configuration.model = "synthetic-old-model"
        configuration.language = KDLocalizer.language
        configuration.preferences.aliases["synthetic-command"] = "keep-alias"
        if existingFile {
            // 非标准空白是合法旧文件；回滚要恢复原字节，而不是重编码当前对象。
            let bytes = Data(" \n".utf8) + (try JSONEncoder().encode(configuration)) + Data("\n".utf8)
            try PrivateFiles.write(bytes, to: directory.appendingPathComponent("configuration.json"))
            originalBytes = bytes
        } else { originalBytes = nil }
        do {
            store = try WorkbenchModel(dataDirectory: directory, allowContextCapture: true,
                clipboardWriter: { _ in }, clipboardChangeCount: { 0 }, clipboardReader: { nil },
                credentialReader: { try credentials.read($0) },
                credentialWriter: { try credentials.write($0, account: $1) }, configurationWriter: writer,
                applicationCatalog: ApplicationCatalog(roots: []))
            original = store.configuration
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    @discardableResult func save(endpoint: String = endpoint, key: String = "synthetic-new-key") -> Bool {
        store.saveAPIConfiguration(endpoint: endpoint, modelName: "synthetic-new-model", localHTTP: false,
            tokenParameter: "max_tokens", apiKey: key)
    }
    func assertOriginal() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let current = try encoder.encode(store.configuration), before = try encoder.encode(original)
        #expect(current == before)
        if let originalBytes { #expect(try Data(contentsOf: configurationURL) == originalBytes) }
        else { #expect(!FileManager.default.fileExists(atPath: configurationURL.path)) }
    }
    func cleanup() {
        store.shutdown()
        if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: languageKey) }
        else { UserDefaults.standard.removeObject(forKey: languageKey) }
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.serialized) @MainActor struct APIConfigurationPersistenceTests {
    @Test func successfulSavePublishesConfigurationAndCredentialTogether() throws {
        let credentials = MemoryCredentials([APIAtomicityFixture.endpoint: "synthetic-old-key"])
        let fixture = try APIAtomicityFixture(credentials: credentials); defer { fixture.cleanup() }
        #expect(fixture.save())
        #expect(credentials.values[APIAtomicityFixture.endpoint] == "synthetic-new-key")
        #expect(credentials.writes.count == 1)
        let persisted = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fixture.configurationURL))
        #expect(persisted.model == "synthetic-new-model" && fixture.store.configuration.model == persisted.model)
        #expect(persisted.tokenLimitParameter == "max_tokens")
        let bytes = try Data(contentsOf: fixture.configurationURL)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("synthetic-new-key"))
    }

    @Test(arguments: APIWriteFault.allCases) func configurationWriteFailureRestoresSameEndpointKeyAndExactFile(_ fault: APIWriteFault) throws {
        let credentials = MemoryCredentials([APIAtomicityFixture.endpoint: "synthetic-old-key"])
        var writes = 0
        let fixture = try APIAtomicityFixture(credentials: credentials, writer: { bytes, url in
            writes += 1
            if writes == 1 && fault == .before { throw SyntheticPersistenceFailure.configurationWrite }
            try PrivateFiles.write(bytes, to: url)
            if writes == 1 { throw SyntheticPersistenceFailure.configurationWrite }
        }); defer { fixture.cleanup() }
        #expect(!fixture.save())
        #expect(credentials.values[APIAtomicityFixture.endpoint] == "synthetic-old-key")
        #expect(credentials.writes.count == 2)
        #expect(writes == (fault == .before ? 1 : 2))
        try fixture.assertOriginal()
        #expect(fixture.store.settingsNotice == L("API configuration could not be saved; active settings were preserved"))
    }

    @Test func failedEndpointSwitchRemovesNewCredentialWithoutTouchingOldService() throws {
        let destination = "https://synthetic-other.invalid/chat/completions"
        let credentials = MemoryCredentials([APIAtomicityFixture.endpoint: "synthetic-old-key"])
        var writes = 0
        let fixture = try APIAtomicityFixture(credentials: credentials, writer: { bytes, url in
            writes += 1; try PrivateFiles.write(bytes, to: url)
            if writes == 1 { throw SyntheticPersistenceFailure.configurationWrite }
        }); defer { fixture.cleanup() }
        #expect(!fixture.save(endpoint: destination))
        #expect(credentials.values[destination] == nil)
        #expect(credentials.values[APIAtomicityFixture.endpoint] == "synthetic-old-key")
        #expect(credentials.writes.last?.key == "" && credentials.writes.last?.account == destination)
        try fixture.assertOriginal()
    }

    @Test func aFailedFirstSaveRestoresAbsentFileAndAbsentCredential() throws {
        let credentials = MemoryCredentials([:])
        let fixture = try APIAtomicityFixture(credentials: credentials, existingFile: false, writer: { bytes, url in
            try PrivateFiles.write(bytes, to: url)
            throw SyntheticPersistenceFailure.configurationWrite
        }); defer { fixture.cleanup() }
        #expect(!fixture.save())
        #expect(credentials.values.isEmpty)
        try fixture.assertOriginal()
    }

    @Test func credentialWriterThrowingAfterMutationIsCompensatedBeforeAnyConfigurationWrite() throws {
        let credentials = MemoryCredentials([APIAtomicityFixture.endpoint: "synthetic-old-key"])
        credentials.failAfterWrite = [1]
        var writes = 0
        let fixture = try APIAtomicityFixture(credentials: credentials, writer: { bytes, url in
            writes += 1; try PrivateFiles.write(bytes, to: url)
        }); defer { fixture.cleanup() }
        #expect(!fixture.save())
        #expect(credentials.values[APIAtomicityFixture.endpoint] == "synthetic-old-key")
        #expect(writes == 0)
        try fixture.assertOriginal()
    }

    @Test(arguments: APIRollbackFault.allCases) func rollbackFailureIsExplicitAndDoesNotSkipTheOtherCompensation(_ fault: APIRollbackFault) throws {
        let credentials = MemoryCredentials([APIAtomicityFixture.endpoint: "synthetic-old-key"])
        if fault == .credential { credentials.failBeforeWrite = [2] }
        var writes = 0
        let fixture = try APIAtomicityFixture(credentials: credentials, writer: { bytes, url in
            writes += 1
            if writes == 2 && fault == .configuration { throw SyntheticPersistenceFailure.configurationWrite }
            try PrivateFiles.write(bytes, to: url)
            if writes == 1 { throw SyntheticPersistenceFailure.configurationWrite }
        }); defer { fixture.cleanup() }
        #expect(!fixture.save())
        #expect(fixture.store.configuration.model == "synthetic-old-model")
        #expect(fixture.store.settingsNotice == L("API configuration could not be saved and rollback was incomplete. Check the saved endpoint and API key before retrying."))
        if fault == .credential {
            #expect(credentials.values[APIAtomicityFixture.endpoint] == "synthetic-new-key")
            #expect(try Data(contentsOf: fixture.configurationURL) == fixture.originalBytes)
        } else {
            #expect(credentials.values[APIAtomicityFixture.endpoint] == "synthetic-old-key")
            let file = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fixture.configurationURL))
            #expect(file.model == "synthetic-new-model")
        }
    }

    @Test func failingToReadOriginalCredentialMakesNoChanges() throws {
        let credentials = MemoryCredentials([APIAtomicityFixture.endpoint: "synthetic-old-key"])
        credentials.readFailures = [1]
        var writes = 0
        let fixture = try APIAtomicityFixture(credentials: credentials, writer: { _, _ in writes += 1 })
        defer { fixture.cleanup() }
        #expect(!fixture.save())
        #expect(credentials.writes.isEmpty && writes == 0)
        try fixture.assertOriginal()
    }

    @Test func leavingAPIKeyBlankPreservesItWithoutReadingOrRewritingIt() throws {
        let credentials = MemoryCredentials([APIAtomicityFixture.endpoint: "synthetic-old-key"])
        let fixture = try APIAtomicityFixture(credentials: credentials); defer { fixture.cleanup() }
        #expect(fixture.save(key: ""))
        #expect(credentials.reads == 0 && credentials.writes.isEmpty)
        #expect(credentials.values[APIAtomicityFixture.endpoint] == "synthetic-old-key")
    }
}
