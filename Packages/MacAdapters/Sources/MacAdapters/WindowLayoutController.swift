import AppKit
@preconcurrency import ApplicationServices
import CommandCore

public enum WindowLayoutError: Error { case unavailable, expired, busy, unsupported, changed, verificationFailed }

@MainActor public final class WindowLayoutController {
    private struct Entry { let reference: WindowReference; let frame: WindowFrame }
    private var originals: [String: Entry] = [:]
    private var active: Set<String> = []
    private var order: [String] = []
    private var closed = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public func close() { closed = true; for cancel in cancellations.values { cancel() } }
    public func apply(_ layout: WindowLayout, target: DesktopWindowTarget, lease: DesktopOperationLease, restoreFocus: Bool = false) async throws {
        try lease.begin()
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        if restoreFocus { try await DesktopApplicationFocus.activate(target.identity, lease: lease) }
        try await apply(layout, reference: target.reference, lease: lease)
    }
    private func apply(_ layout: WindowLayout, reference ref: WindowReference, lease: DesktopOperationLease?) async throws {
        guard !closed else { throw CancellationError() }
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        try lease?.check()
        try validate(ref)
        guard !active.contains(ref.id) else { throw WindowLayoutError.busy }
        let operation = UUID()
        active.insert(ref.id); defer { active.remove(ref.id); cancellations[operation] = nil }
        let screens = displays()
        let read = Task.detached { try Self.readFrame(ref) }
        cancellations[operation] = { read.cancel() }
        let current = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        try Task.checkCancellation(); try lease?.check(); guard !closed else { throw CancellationError() }; try validate(ref)
        let old = originals[ref.id].flatMap { CFEqual($0.reference.element, ref.element) ? $0.frame : nil }
        let destination = try WindowGeometry.frame(for: layout, current: current, displays: screens, restore: old)
        // 原始frame在任何AX写入前保留；失败或部分变更也仍有明确恢复入口。
        if layout != .restore && old == nil { originals[ref.id] = Entry(reference: ref, frame: current); order.append(ref.id) }
        let write = Task.detached { try Self.writeFrame(destination, expected: current, reference: ref, lease: lease) }
        cancellations[operation] = { lease?.revoke(); write.cancel() }
        try await withTaskCancellationHandler { try await write.value } onCancel: { lease?.revoke(); write.cancel() }
        try Task.checkCancellation(); try lease?.check()
        guard !closed else { throw CancellationError() }; try validate(ref)
        if layout == .restore { originals[ref.id] = nil; order.removeAll{$0 == ref.id} }
        // 仅保留有限的窗口级引用，不将关闭窗口或PID复用的状态写磁盘。
        while originals.count > 200, let first = order.first(where:{!active.contains($0)}) { originals[first] = nil; order.removeAll{$0 == first} }
    }
    private func validate(_ ref: WindowReference) throws {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: ref.pid), !app.isTerminated,
              ref.launchDate != nil, app.launchDate == ref.launchDate else { throw WindowLayoutError.expired }
    }
    private func displays() -> [DisplayGeometry] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.enumerated().map { index,screen in
            let f = screen.visibleFrame
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? String(index)
            return DisplayGeometry(id: id, visibleFrame: WindowFrame(x: f.minX,y:top-f.maxY,width:f.width,height:f.height))
        }
    }
    nonisolated private static func readFrame(_ ref: WindowReference) throws -> WindowFrame {
        try Task.checkCancellation()
        guard let windows = try? AX.boundedWindowElements(AX.application(ref.pid)), windows.contains(where: { CFEqual($0,ref.element) }),
              let p = AX.read(ref.element,kAXPositionAttribute), let s = AX.read(ref.element,kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw WindowLayoutError.expired }
        var point = CGPoint.zero; var size = CGSize.zero
        let position = p as! AXValue, dimension = s as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(dimension) == .cgSize,
              AXValueGetValue(position,.cgPoint,&point), AXValueGetValue(dimension,.cgSize,&size) else { throw WindowLayoutError.unsupported }
        let frame = WindowFrame(x:point.x,y:point.y,width:size.width,height:size.height)
        guard frame.valid else { throw WindowLayoutError.unsupported }; return frame
    }
    nonisolated private static func writeFrame(_ frame: WindowFrame, expected: WindowFrame, reference ref: WindowReference, lease: DesktopOperationLease?) throws {
        try lease?.check()
        guard try readFrame(ref).approximatelyEquals(expected) else { throw WindowLayoutError.changed }
        var point = CGPoint(x:frame.x,y:frame.y); var size = CGSize(width:frame.width,height:frame.height)
        var positionWritable = DarwinBoolean(false), sizeWritable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(ref.element,kAXPositionAttribute as CFString,&positionWritable) == .success,
              AXUIElementIsAttributeSettable(ref.element,kAXSizeAttribute as CFString,&sizeWritable) == .success,
              positionWritable.boolValue, sizeWritable.boolValue,
              let position = AXValueCreate(.cgPoint,&point), let dimension = AXValueCreate(.cgSize,&size) else { throw WindowLayoutError.unsupported }
        try Task.checkCancellation()
        try lease?.markSubmission()
        guard AXUIElementSetAttributeValue(ref.element,kAXPositionAttribute as CFString,position) == .success else { throw WindowLayoutError.unsupported }
        try lease?.check()
        guard AXUIElementSetAttributeValue(ref.element,kAXSizeAttribute as CFString,dimension) == .success else { throw WindowLayoutError.unsupported }
        try Task.checkCancellation()
        try lease?.check()
        guard AXUIElementSetAttributeValue(ref.element,kAXPositionAttribute as CFString,position) == .success,
              try readFrame(ref).approximatelyEquals(frame) else { throw WindowLayoutError.verificationFailed }
    }
}
