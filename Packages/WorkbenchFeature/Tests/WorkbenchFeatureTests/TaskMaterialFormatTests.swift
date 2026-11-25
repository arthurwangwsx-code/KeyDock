import Foundation
import Testing
@testable import WorkbenchFeature

struct TaskMaterialFormatTests {
    private let key = TaskMaterialKey(receiptStore: .ai, invocationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, receiptRecordIdentity: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let version = TaskMaterialVersion(identity: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, revision: 1)

    @Test func exactFramingAndUnicodeInputSurviveRoundTrip() throws {
        let text = "e\u{301}\n中文 👩🏽‍💻\u{0001}"
        let selected = SelectedTaskMaterial(input: text, visibleResult: "synthetic result", resultKind: .visibleResult, resultWasPartial: true, resultCapturedAt: 999)
        let (frame, encoded) = try TaskMaterialFormat.frame(selected, key: key, version: version, createdAt: 1_000, expiresAt: 2_000)
        #expect(frame.prefix(8) == Data("KDMAT001".utf8))
        let count = try TaskMaterialFormat.headerLength(Data(frame.prefix(12)))
        let bytes = frame.subdata(in: 12..<(12 + count))
        let header = try TaskMaterialFormat.decodeHeader(bytes, fileBytes: frame.count, headerBytes: count)
        #expect(header.payloadSHA256 == encoded.payloadSHA256)
        #expect(header.key == key && header.version == version)
        let result = try TaskMaterialFormat.decodePayload(frame.subdata(in: (12 + count)..<frame.count), header: header)
        #expect(result.input?.utf8.elementsEqual(text.utf8) == true)
        #expect(result.input?.utf8.elementsEqual("é\n中文 👩🏽‍💻\u{0001}".utf8) == false)
        #expect(header.fields == [.input, .visibleResult])
    }

    @Test func accurateEmptyInputIsDifferentFromNoSelectedFields() throws {
        let (frame, header) = try TaskMaterialFormat.frame(.init(input: ""), key: key, version: version, createdAt: 10, expiresAt: 11)
        #expect(header.fields == [.input] && header.rawBytes == 0 && !frame.isEmpty)
        #expect(throws: TaskMaterialError.invalidContent) {
            try TaskMaterialFormat.frame(.init(), key: key, version: version, createdAt: 10, expiresAt: 11)
        }
        let cli = TaskMaterialKey(receiptStore: .cli, invocationID: key.invocationID, receiptRecordIdentity: key.receiptRecordIdentity)
        #expect(throws: TaskMaterialError.invalidContent) {
            try TaskMaterialFormat.frame(.init(input: "not argv or env"), key: cli, version: version, createdAt: 10, expiresAt: 11)
        }
    }

    @Test func rawAndEscapedEncodingBudgetsRejectEntireRecord() throws {
        #expect(throws: TaskMaterialError.invalidContent) {
            try TaskMaterialFormat.frame(.init(input: String(repeating: "x", count: TaskMaterialLimits.inputBytes + 1)), key: key, version: version, createdAt: 10, expiresAt: 11)
        }
        let inflated = String(repeating: "\u{0001}", count: TaskMaterialLimits.outputBytes)
        #expect(throws: TaskMaterialError.capacity) {
            try TaskMaterialFormat.frame(.init(visibleResult: inflated, resultKind: .agentIncludingToolReturns, resultWasPartial: false, resultCapturedAt: 9), key: key, version: version, createdAt: 10, expiresAt: 11)
        }
    }

    @Test func corruptDigestFutureFrameAndTrailingPayloadAreRejected() throws {
        let (frame, header) = try TaskMaterialFormat.frame(.init(input: "synthetic"), key: key, version: version, createdAt: 10, expiresAt: 11)
        let length = try TaskMaterialFormat.headerLength(Data(frame.prefix(12)))
        #expect(throws: TaskMaterialError.unsupportedFormat) {
            try TaskMaterialFormat.headerLength(Data("KDMAT002".utf8) + Data([0, 0, 0, 1]))
        }
        #expect(throws: TaskMaterialError.invalidHeader) {
            try TaskMaterialFormat.decodeHeader(frame.subdata(in: 12..<(12 + length)), fileBytes: frame.count + 1, headerBytes: length)
        }
        #expect(throws: TaskMaterialError.changed) { try TaskMaterialFormat.decodePayload(Data("{}".utf8), header: header) }
    }

    @Test func fileNameIsCanonicalAndDoesNotInterpretArbitraryUnicodePaths() throws {
        #expect(TaskMaterialKey.fromFileName(key.fileName) == key)
        #expect(TaskMaterialKey.fromFileName(key.fileName.uppercased()) == nil)
        #expect(TaskMaterialKey.fromFileName("../" + key.fileName) == nil)
        #expect(TaskMaterialKey.fromFileName("ai-" + String(repeating: "你", count: 24) + "a.kdmaterial") == nil)
    }

    @Test func checkpointMustBelongToTheSameRunAndBoundedSuccessfulMaterial() throws {
        let checkpoint = TaskMaterialCheckpoint(runID: UUID(), definitionID: UUID(), definitionVersion: 1,
            stepID: UUID(), stepIndex: 0, sequence: 1, input: "synthetic", output: "synthetic")
        #expect(throws: TaskMaterialError.invalidContent) {
            try TaskMaterialFormat.frame(.init(successfulCheckpoint: checkpoint), key: key, version: version, createdAt: 10, expiresAt: 11)
        }
    }

    @Test func unknownNestedMetadataAndBodyFieldsAreNotSilentlyDiscarded() throws {
        let (frame, header) = try TaskMaterialFormat.frame(.init(input: "synthetic"), key: key, version: version, createdAt: 10, expiresAt: 11)
        let length = try TaskMaterialFormat.headerLength(Data(frame.prefix(12)))
        var object = try #require(JSONSerialization.jsonObject(with: frame.subdata(in: 12..<(12 + length))) as? [String: Any])
        var birth = try #require(object["key"] as? [String: Any]); birth["runtimeGrant"] = true; object["key"] = birth
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: TaskMaterialError.unsupportedFormat) {
            try TaskMaterialFormat.decodeHeader(bytes, fileBytes: 12 + bytes.count + header.payloadBytes, headerBytes: bytes.count)
        }
        let unexpected = Data("{\"input\":\"synthetic\",\"systemPrompt\":\"must not be retained\"}".utf8)
        let modified = TaskMaterialHeader(formatVersion: 1, key: key, version: version, createdAt: 10, expiresAt: 11,
            fields: [.input], resultKind: nil, resultWasPartial: nil, resultCapturedAt: nil, rawBytes: 9, payloadBytes: unexpected.count, payloadSHA256: TaskMaterialFormat.digest(unexpected))
        #expect(throws: TaskMaterialError.unsupportedFormat) { try TaskMaterialFormat.decodePayload(unexpected, header: modified) }
    }

    @Test func fixedCrossLanguageGoldenPreservesExactInputAndControlStates() throws {
        let url = TaskMaterialTestFixtures.repositoryRoot.appendingPathComponent("Tools/Fixtures/task-material-v1.json")
        let fixtureData = try Data(contentsOf: url)
        let fixture = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        let frameBase64 = try #require(fixture["frameBase64"] as? String)
        let frame = try #require(Data(base64Encoded: frameBase64))
        #expect(TaskMaterialFormat.digest(frame) == fixture["frameSHA256"] as? String)
        let count = try TaskMaterialFormat.headerLength(Data(frame.prefix(12)))
        let header = try TaskMaterialFormat.decodeHeader(frame.subdata(in: 12..<(12 + count)), fileBytes: frame.count, headerBytes: count)
        #expect(header.key.fileName == fixture["fileName"] as? String)
        let payload = try TaskMaterialFormat.decodePayload(frame.subdata(in: (12 + count)..<frame.count), header: header)
        let inputBase64 = try #require(fixture["inputUTF8Base64"] as? String)
        let expected = try #require(Data(base64Encoded: inputBase64))
        #expect(payload.input.map { Data($0.utf8) } == expected)
        for name in ["controlIdleBase64", "controlPendingWriteBase64", "controlDeletionBase64"] {
            let base64 = try #require(fixture[name] as? String)
            let bytes = try #require(Data(base64Encoded: base64))
            let control = try TaskMaterialControl.decode(bytes)
            #expect((control.pendingWrite != nil) == (name == "controlPendingWriteBase64"))
            #expect((control.deletion != nil) == (name == "controlDeletionBase64"))
        }
    }
}
