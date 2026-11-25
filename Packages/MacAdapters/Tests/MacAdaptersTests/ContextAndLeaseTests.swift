import Foundation
import Testing
import PDFKit
import CoreText
import ImageIO
import AppKit
import Vision
import CoreML
import CryptoKit
@testable import MacAdapters

@Suite(.serialized) struct ContextAndLeaseTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keydock-context-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    @Test func onlyOneDirectoryOwnerAndReacquireAfterRelease() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        var lease: RuntimeDirectoryLease? = try RuntimeDirectoryLease(directory:dir)
        #expect(throws:RuntimeDirectoryLeaseError.alreadyOwned) { _ = try RuntimeDirectoryLease(directory:dir) }
        withExtendedLifetime(lease) {}; lease = nil
        let next = try RuntimeDirectoryLease(directory:dir); withExtendedLifetime(next) {}
    }
    @Test func ownerRejectsSymlinkLockWithoutTouchingTarget() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let target = dir.appendingPathComponent("owned.txt"), data = Data("fixture".utf8)
        try data.write(to:target); try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("runtime-owner.lock"),withDestinationURL:target)
        #expect(throws:(any Error).self) { _ = try RuntimeDirectoryLease(directory:dir) }
        #expect(try Data(contentsOf:target) == data)
    }
    @Test func explicitUTF8HasBasenameOnlyAndRejectsBinaryAndOversize() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("Synthetic.md")
        try Data("Synthetic 中文 input".utf8).write(to:url)
        let result = try await DocumentContextService.read(url)
        #expect(result.text == "Synthetic 中文 input" && result.displayName == "Synthetic.md" && !result.usedOCR && result.extraction == .text)
        try Data([0,1,2]).write(to:url)
        await #expect(throws:DocumentContextError.unsupported) { _ = try await DocumentContextService.read(url) }
        try Data(repeating:65,count:131_073).write(to:url)
        await #expect(throws:DocumentContextError.unsupported) { _ = try await DocumentContextService.read(url) }
    }
    @MainActor @Test func selectedPDFExtractsLocallyAndCancelledReadDoesNotPublish() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("Synthetic.pdf")
        let text = NSAttributedString(string:"Synthetic PDF context")
        // 标准文本导出生成独占合成PDF，未读取个人文件。
        let view = NSTextView(frame:NSRect(x:0,y:0,width:320,height:100)); view.textStorage?.setAttributedString(text)
        try view.dataWithPDF(inside:view.bounds).write(to:url)
        let result = try await DocumentContextService.read(url)
        #expect(result.text.contains("Synthetic PDF context") && !result.usedOCR && result.extraction == .pdfText)
        let task = Task { try Task.checkCancellation(); return try await DocumentContextService.read(url) }; task.cancel()
        if case .success = await task.result { Issue.record("Cancelled extraction unexpectedly succeeded") }
    }
    @Test func searchResultCannotBeRevealedUnderAnotherAllowedRoot() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true); try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
        try Data("body".utf8).write(to:a.appendingPathComponent("match.txt"))
        let service = try FileSearchService(), result = try #require(try await service.search(query:"match",roots:[a]).results.first)
        await #expect(throws:FileSearchError.scopeChanged) { _ = try await service.validate(result,allowedRoots:[b]) }
        #expect(try await service.validate(result,allowedRoots:[a]).lastPathComponent == "match.txt")
    }
}

extension ContextAndLeaseTests {
    @Test func visionRecognizesOnlyAnOwnedSyntheticImage() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("Synthetic.png")
        let width = 1200, height = 200
        let context = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.textPosition = CGPoint(x:40,y:80)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:"KEYDOCK SYNTHETIC CONTEXT",attributes:[.font:NSFont.systemFont(ofSize:60),.foregroundColor:NSColor.black]))
        CTLineDraw(line,context)
        let image = try #require(context.makeImage()), destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil); #expect(CGImageDestinationFinalize(destination))
        var rounds: [[String:Bool]] = []
        let started = ProcessInfo.processInfo.systemUptime
        for round in 1...2 {
            print("KEYDOCK_OCR_ROUND round=\(round) event=start elapsed=\(ProcessInfo.processInfo.systemUptime-started)")
            let value: DocumentText
            do { value = try await DocumentContextService.read(url) }
            catch {
                let failure = error as NSError, underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                Issue.record("Synthetic OCR failed: round=\(round), elapsed=\(ProcessInfo.processInfo.systemUptime-started), domain=\(failure.domain), code=\(failure.code), underlyingDomain=\(underlying?.domain ?? "none"), underlyingCode=\(underlying?.code ?? 0)")
                throw error
            }
            let outcome = ["usedOCR":value.usedOCR,"hasKeyDock":value.text.uppercased().contains("KEYDOCK"),"hasSynthetic":value.text.uppercased().contains("SYNTHETIC")]
            print("KEYDOCK_OCR_ROUND round=\(round) event=finished matched=\(outcome.values.allSatisfy{$0}) elapsed=\(ProcessInfo.processInfo.systemUptime-started)")
            #expect(outcome.values.allSatisfy{$0}); rounds.append(outcome)
        }
        let request = try DocumentContextService.makeOCRRequest()
        var cpuStages = 0, cpuMatches = true
        for (stage,devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where:{if case .cpu = $0 {return true}; return false}) { cpuStages += 1; cpuMatches = cpuMatches && request.computeDevice(for:stage) == cpu }
        }
        #expect(request.recognitionLevel == .accurate && request.automaticallyDetectsLanguage && request.usesLanguageCorrection && request.revision == 3 && cpuStages > 0 && cpuMatches)
        let record: [String:Any] = ["configuration":["level":"accurate","automaticLanguage":request.automaticallyDetectsLanguage,"languageCorrection":request.usesLanguageCorrection,"revision":request.revision,"supportedCPUsAssigned":cpuStages > 0 && cpuMatches],"rounds":rounds,"fixtureSHA256":SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()]
        print("KEYDOCK_OCR_QUALIFICATION "+String(decoding:try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),as:UTF8.self))
    }
}
