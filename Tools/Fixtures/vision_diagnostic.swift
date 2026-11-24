import AppKit
import CoreML
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Vision

// 仅诊断本工具生成的图片；没有文件选择、截图、个人数据输入或产品验收捷径。
private struct Scenario: Sendable {
    let id: String
    let languages: [String]?
    let correction: Bool
    static let all = [
        Scenario(id: "accurate-auto", languages: nil, correction: true),
        Scenario(id: "accurate-english", languages: ["en-US"], correction: true),
        Scenario(id: "accurate-english-chinese", languages: ["en-US", "zh-Hans"], correction: true),
        Scenario(id: "accurate-chinese-english", languages: ["zh-Hans", "en-US"], correction: true),
        Scenario(id: "accurate-english-no-correction", languages: ["en-US"], correction: false)
    ]
}

private enum ProbeError: String, Error { case arguments, fixture, image, childOutput, childLaunch }

@main
private struct VisionDiagnostic {
    static let text = "KEYDOCK SYNTHETIC CONTEXT"
    static let childTimeout: TimeInterval = 45

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty { exit(try runAll() ? 0 : 1) }
            guard arguments.count == 3, arguments[0] == "--scenario",
                  let scenario = Scenario.all.first(where: { $0.id == arguments[1] }) else { throw ProbeError.arguments }
            // 子进程只从父进程管道接收有界的同一PNG，不接受任何文件路径。
            var bytes = Data()
            while true {
                let chunk = try FileHandle.standardInput.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty { break }
                guard bytes.count + chunk.count <= 1_048_576 else { throw ProbeError.fixture }
                bytes.append(chunk)
            }
            guard bytes.count <= 1_048_576, digest(bytes) == arguments[2] else { throw ProbeError.fixture }
            // 与生产提取路径一致：Vision在后台执行，主线程可以处理框架服务回调。
            let succeeded = await Task.detached(priority:.userInitiated) { run(scenario,bytes:bytes) }.value
            exit(succeeded ? 0 : 1)
        } catch {
            emit(["type": "diagnostic-setup", "status": "error", "product_acceptance": false, "error": errorInfo(error)])
            exit(2)
        }
    }

    static func runAll() throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-OCR-Diagnostic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("Synthetic.png")
        try createFixture(fixture)
        let bytes = try Data(contentsOf: fixture)
        let sha = digest(bytes)
        emit(["type": "fixture", "product_acceptance": false, "sha256": sha,
              "width": 1200, "height": 200, "bytes": bytes.count, "text": text,
              "os": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": architecture,
              "image_os": ProcessInfo.processInfo.environment["ImageOS"] ?? "unreported",
              "image_version": ProcessInfo.processInfo.environment["ImageVersion"] ?? "unreported",
              "scenario_timeout_seconds": childTimeout])
        var succeeded = true
        for scenario in Scenario.all {
            do {
                if try !runChild(scenario, bytes: bytes, sha: sha, directory: directory) { succeeded = false }
            } catch {
                succeeded = false
                emit(["type": "ocr-scenario", "scenario": scenario.id, "product_acceptance": false,
                      "status": "child-error", "error": errorInfo(error)])
            }
        }
        emit(["type": "diagnostic-summary", "product_acceptance": false,
              "status": succeeded ? "all-diagnostic-scenarios-recognized" : "diagnostic-failures-observed",
              "scenario_count": Scenario.all.count])
        return succeeded
    }

    // 每个场景冷启动独立的本工具进程；超时仅结束本工具创建的子进程。
    static func runChild(_ scenario: Scenario, bytes: Data, sha: String, directory: URL) throws -> Bool {
        let outputURL = directory.appendingPathComponent(scenario.id + ".json")
        let errorURL = directory.appendingPathComponent(scenario.id + ".stderr")
        for url in [outputURL, errorURL] {
            guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw ProbeError.childOutput }
        }
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let child = Process(), input = Pipe()
        guard let executable = Bundle.main.executableURL else { throw ProbeError.childLaunch }
        child.executableURL = executable
        child.arguments = ["--scenario", scenario.id, sha]
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        try child.run()
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + childTimeout
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        var timedOut = false
        if child.isRunning {
            timedOut = true; child.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        try output.synchronize(); try errors.synchronize()
        let diagnosticStderr = try boundedString(errorURL)
        if timedOut {
            emit(["type": "ocr-scenario", "scenario": scenario.id, "product_acceptance": false,
                  "status": "timeout", "timeout_seconds": childTimeout, "stderr": diagnosticStderr])
            return false
        }
        let handle = try FileHandle(forReadingFrom: outputURL); defer { try? handle.close() }
        let data = try handle.read(upToCount: 262_145) ?? Data()
        guard data.count <= 262_144,
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            emit(["type":"ocr-scenario","scenario":scenario.id,"product_acceptance":false,
                  "status":"invalid-child-output","child_exit_status":child.terminationStatus,
                  "stdout":String(decoding:data.prefix(65_536),as:UTF8.self),"stderr":diagnosticStderr])
            return false
        }
        record["child_exit_status"] = child.terminationStatus
        record["stderr"] = diagnosticStderr
        emit(record)
        return child.terminationReason == .exit && child.terminationStatus == 0
    }

    static func run(_ scenario: Scenario, bytes: Data) -> Bool {
        var record: [String: Any] = ["type": "ocr-scenario", "scenario": scenario.id,
            "product_acceptance": false, "fixture_sha256": digest(bytes), "recognition_level": "accurate",
            "recognition_on_main_thread": Thread.isMainThread,
            "automatically_detects_language": scenario.languages == nil, "language_correction": scenario.correction]
        var phase = "decode"
        let start = ProcessInfo.processInfo.systemUptime
        do {
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 1200, image.height == 200 else { throw ProbeError.image }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = scenario.correction
            request.automaticallyDetectsLanguage = scenario.languages == nil
            if let languages = scenario.languages { request.recognitionLanguages = languages }
            record["request_revision"] = request.revision
            record["default_revision"] = VNRecognizeTextRequest.defaultRevision
            record["current_revision"] = VNRecognizeTextRequest.currentRevision
            record["supported_revisions"] = Array(VNRecognizeTextRequest.supportedRevisions)
            record["configured_languages"] = request.recognitionLanguages
            // 查询失败单独记录；不会把失败伪装为语言已受支持。
            do { record["supported_languages"] = try request.supportedRecognitionLanguages() }
            catch { record["supported_languages_error"] = errorInfo(error) }
            phase = "compute-device-query"
            let stages = try request.supportedComputeStageDevices
            var devices: [[String: Any]] = []
            for (stage, supported) in stages.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let cpu = supported.first { if case .cpu = $0 { return true }; return false }
                if let cpu { request.setComputeDevice(cpu, for: stage) }
                devices.append(["stage": stage.rawValue, "supported": supported.map(deviceInfo),
                                "selected": cpu.map(deviceInfo) ?? ["type": "vision-default"]])
            }
            record["compute_stages"] = devices
            phase = "perform"
            try VNImageRequestHandler(cgImage: image).perform([request])
            let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let matches = recognized.uppercased().contains("KEYDOCK") && recognized.uppercased().contains("SYNTHETIC")
            record["recognized_text"] = String(recognized.prefix(4096))
            record["synthetic_assertion_matched"] = matches
            record["status"] = matches ? "recognized" : "recognition-mismatch"
            record["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - start
            emit(record); return matches
        } catch {
            record["status"] = "error"; record["failure_phase"] = phase
            record["error"] = errorInfo(error); record["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - start
            emit(record); return false
        }
    }

    static func createFixture(_ url: URL) throws {
        guard let context = CGContext(data: nil, width: 1200, height: 200, bitsPerComponent: 8, bytesPerRow: 4800,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ProbeError.fixture }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 200))
        context.textPosition = CGPoint(x: 40, y: 80)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 60), .foregroundColor: NSColor.black]))
        CTLineDraw(line, context)
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw ProbeError.fixture }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProbeError.fixture }
    }

    static func deviceInfo(_ device: MLComputeDevice) -> [String: String] {
        let type: String
        switch device { case .cpu: type = "cpu"; case .gpu: type = "gpu"; case .neuralEngine: type = "neural-engine"; @unknown default: type = "unknown" }
        return ["type": type, "description": String(String(describing: device).prefix(512))]
    }
    static func errorInfo(_ error: Error, depth: Int = 0) -> [String: Any] {
        let value = error as NSError
        var result: [String: Any] = ["domain": value.domain, "code": value.code,
            "localized_description": String(value.localizedDescription.prefix(4096)),
            "swift_description": String(String(reflecting: error).prefix(4096))]
        if depth < 4, let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
            result["underlying"] = errorInfo(underlying, depth: depth + 1)
        } else { result["underlying"] = NSNull() }
        return result
    }
    static func boundedString(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return String(decoding: try handle.read(upToCount: 65_536) ?? Data(), as: UTF8.self)
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "other"
        #endif
    }
    static func emit(_ record: [String: Any]) {
        do { var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10); try FileHandle.standardOutput.write(contentsOf: data) }
        catch { try? FileHandle.standardError.write(contentsOf: Data("Unable to encode diagnostic JSON.\n".utf8)); exit(2) }
    }
}
