import AppKit
import Vision
import CoreML
import PDFKit
import ImageIO
import ExecutionCore
import UniformTypeIdentifiers
import Darwin

public enum DocumentContextError: Error, Equatable { case unsupported, tooLarge, invalidFile, noText, screenPermissionRequired, cancelled, captureFailed }
public struct DocumentText: Sendable {
    public let displayName: String
    public let text: String
    public let usedOCR: Bool
}

/// 仅处理用户明确选中的单个文件或截图；没有目录扫描、自动上传或截图历史。
private final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func install(_ value: VNRequest) { lock.lock(); request = value; let stop = cancelled; lock.unlock(); if stop { value.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let value = request; lock.unlock(); value?.cancel() }
}
public enum DocumentContextService {
    // 资格测试与实际提取共用此工厂，不能以另一种识别模式冒充生产结果。
    static func makeOCRRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest(); request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
        for (stage,devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where:{ if case .cpu = $0 { return true }; return false }) { request.setComputeDevice(cpu,for:stage) }
        }
        return request
    }
    public static func read(_ url: URL) async throws -> DocumentText {
        let cancellation = OCRCancellation()
        let task = Task.detached(priority:.userInitiated) { try extract(url,cancellation:cancellation) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { cancellation.cancel(); task.cancel() }
    }
    private static func extract(_ url: URL,cancellation:OCRCancellation) throws -> DocumentText {
        try Task.checkCancellation()
        guard url.isFileURL else { throw DocumentContextError.invalidFile }
        let fd = Darwin.open(url.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        guard fd >= 0 else { throw DocumentContextError.invalidFile }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else { throw DocumentContextError.invalidFile }
        guard info.st_size <= 16*1_048_576 else { throw DocumentContextError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating:0,count:65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw DocumentContextError.invalidFile }
            guard data.count+count <= 16*1_048_576 else { throw DocumentContextError.tooLarge }
            data.append(contentsOf:buffer.prefix(count))
        }
        let text: String, ocr: Bool
        if let image = CGImageSourceCreateWithData(data as CFData,nil), let type = CGImageSourceGetType(image), UTType(type as String)?.conforms(to:.image) == true {
            guard CGImageSourceGetCount(image) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0, width.doubleValue*height.doubleValue <= 20_000_000,
                  let pixels = CGImageSourceCreateImageAtIndex(image,0,[kCGImageSourceShouldCache:false] as CFDictionary) else { throw DocumentContextError.tooLarge }
            let request = try makeOCRRequest()
            // 有界单图文字提取优先使用各阶段明确支持的CPU，减少虚拟机／GPU驱动依赖。
            // 未声明CPU支持的阶段保持Vision默认选择；不构造或强塞不支持的设备。
            cancellation.install(request); try Task.checkCancellation()
            try VNImageRequestHandler(cgImage:pixels).perform([request]); try Task.checkCancellation()
            text = (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n"); ocr = true
        } else if data.starts(with:Data("%PDF-".utf8)) {
            guard let pdf = PDFDocument(data:data), !pdf.isLocked, pdf.pageCount <= 30 else { throw DocumentContextError.unsupported }
            var pages: [String] = [], bytes = 0
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation(); let page = pdf.page(at:index)?.string ?? ""
                bytes += page.utf8.count; guard bytes <= 131_072 else { throw DocumentContextError.tooLarge }; pages.append(page)
            }
            text = pages.joined(separator:"\n\n"); ocr = false
        } else {
            guard data.count <= 131_072, !data.contains(0), let value = String(data:data,encoding:.utf8) else { throw DocumentContextError.unsupported }
            text = value; ocr = false
        }
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw DocumentContextError.noText }
        guard text.utf8.count <= 131_072 else { throw DocumentContextError.tooLarge }
        return DocumentText(displayName:String(url.lastPathComponent.prefix(256)),text:text,usedOCR:ocr)
    }
    @MainActor public static func captureRegion() async throws -> DocumentText {
        guard CGPreflightScreenCaptureAccess() else { throw DocumentContextError.screenPermissionRequired }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-capture-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("Selection.png"), id = UUID(), runner = ProcessRunner()
        let command = SavedCommand(name:"KeyDock region capture",executable:"/usr/sbin/screencapture",arguments:["-i","-x","-t","png",file.path],workingDirectory:directory.path,timeout:120)
        return try await withTaskCancellationHandler {
            var result: ProcessResult?
            for await event in await runner.run(command,id:id) { if case .finished(let value) = event { result = value } }
            if Task.isCancelled { await runner.cancel(id) }; await runner.waitForCompletion(id); try Task.checkCancellation()
            guard result?.state == .succeeded, FileManager.default.fileExists(atPath:file.path) else { throw DocumentContextError.cancelled }
            return try await read(file)
        } onCancel: { Task { await runner.cancel(id) } }
    }
    @MainActor public static func openScreenRecordingSettings() {
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}
