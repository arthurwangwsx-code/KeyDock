import AppKit
@preconcurrency import ApplicationServices
import CommandCore

public enum WindowLayoutError: Error { case unavailable, expired, busy, unsupported, changed, verificationFailed }

@MainActor public final class WindowLayoutController {
    private struct Entry { let reference: WindowReference; let frame: WindowFrame; let operation: UUID }
    private var originals: [UUID: Entry] = [:]
    private var references: [UUID: WindowReference] = [:]
    private var active: Set<UUID> = []
    private var order: [UUID] = []
    private var closed = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private let owner = UUID()
    private let environment: WindowLayoutEnvironment
    public convenience init() {
        let generation = WindowDisplayGeneration()
        self.init(environment: .init(trusted: { AXIsProcessTrusted() }, validate: { target in
            let ref = target.reference
            guard let app = NSRunningApplication(processIdentifier: ref.pid), !app.isTerminated,
                  ref.launchDate != nil, app.launchDate == ref.launchDate else { throw WindowLayoutError.expired }
        }, displays: { (generation.current, Self.liveDisplays()) }, generationIsCurrent: { generation.current == $0 }, read: { try Self.readFrame($0.reference) },
        checkWritable: { try Self.checkWritable($0.reference) }, write: { try Self.writeFrame($0, expected: $1, reference: $2.reference, lease: $3, submission: $4) }))
    }
    init(environment: WindowLayoutEnvironment) { self.environment = environment }
    public func close() { closed = true; for cancel in cancellations.values { cancel() } }

    public func captureDisplaySnapshot() throws -> WindowDisplaySnapshot {
        guard !closed else { throw CancellationError() }
        let (generation, screens) = environment.displays()
        guard !screens.isEmpty, screens.allSatisfy({ $0.visibleFrame.valid }), Set(screens.map(\.id)).count == screens.count else { throw WindowLayoutError.unavailable }
        return WindowDisplaySnapshot(displays: screens, owner: owner, generation: generation)
    }

    /// prepare只读，不能占用Restore基线、激活应用或提交lease。
    public func prepare(_ layout: WindowLayout, target: DesktopWindowTarget, displays: WindowDisplaySnapshot,
                        destinationDisplayID: String? = nil) async throws -> PreparedWindowLayout {
        let key = key(for: target.reference)
        guard !active.contains(key) else { throw WindowLayoutError.busy }
        active.insert(key); defer { active.remove(key); trimOriginals() }
        let current = try await readChecked(target, displays: displays)
        let old = originals[key]
        let selected: [DisplayGeometry]
        if let destinationDisplayID {
            guard let display = displays.displays.first(where: { $0.id == destinationDisplayID }),
                  DesktopWorkspaceEntry.allowedLayouts.contains(layout) else { throw WindowLayoutError.unsupported }
            selected = [display]
        } else { selected = displays.displays }
        let destination = try WindowGeometry.frame(for: layout, current: current, displays: selected, restore: old?.frame)
        return PreparedWindowLayout(target: target, original: current, destination: destination, displays: displays, layout: layout, restoreOperation: layout == .restore ? old?.operation : nil)
    }

    /// 批次在第一次写入前复核所有计划；执行时仍须逐项再次复核。
    public func revalidate(_ plan: PreparedWindowLayout) async throws {
        let key = key(for: plan.target.reference)
        guard !active.contains(key) else { throw WindowLayoutError.busy }
        active.insert(key); defer { active.remove(key); trimOriginals() }
        try validateRestore(plan, key: key)
        let frame = try await readChecked(plan.target, displays: plan.displays)
        guard frame.approximatelyEquals(plan.originalFrame) else { throw WindowLayoutError.changed }
    }

    public func applyPrepared(_ plan: PreparedWindowLayout, lease: DesktopOperationLease) async throws {
        try lease.begin()
        try await execute(plan, lease: lease)
    }
    public func apply(_ layout: WindowLayout, target: DesktopWindowTarget, lease: DesktopOperationLease, restoreFocus: Bool = false) async throws {
        try lease.begin()
        guard environment.trusted() else { throw DesktopError.accessibilityRequired }
        if restoreFocus { try await DesktopApplicationFocus.activate(target.identity, lease: lease) }
        let plan = try await prepare(layout, target: target, displays: captureDisplaySnapshot())
        try lease.check()
        try await execute(plan, lease: lease)
    }

    private func execute(_ plan: PreparedWindowLayout, lease: DesktopOperationLease) async throws {
        guard plan.displays.owner == owner else { throw WindowLayoutError.changed }
        try plan.claim(); try lease.check()
        let target = plan.target, ref = target.reference, key = key(for: ref)
        guard !active.contains(key) else { throw WindowLayoutError.busy }
        active.insert(key)
        let generationIsCurrent = environment.generationIsCurrent
        let operation = UUID(), submission = WindowFrameSubmission(isCurrent: { generationIsCurrent(plan.displays.generation) })
        defer {
            // 只撤回本次尚未提交的候选基线；之前的布局／部分写入不被抹掉。
            if !submission.didSubmit, originals[key]?.operation == operation { originals[key] = nil; order.removeAll { $0 == key } }
            active.remove(key); cancellations[operation] = nil; trimOriginals()
        }
        try validateRestore(plan, key: key)
        let current = try await readChecked(target, displays: plan.displays)
        try lease.check()
        guard current.approximatelyEquals(plan.originalFrame) else { throw WindowLayoutError.changed }
        if plan.layout != .restore && originals[key] == nil { originals[key] = Entry(reference: ref, frame: current, operation: operation); order.append(key) }
        let writeFrame = environment.write
        let write = Task.detached { try writeFrame(plan.destinationFrame, plan.originalFrame, target, lease, submission) }
        cancellations[operation] = { lease.revoke(); write.cancel() }
        try await withTaskCancellationHandler { try await write.value } onCancel: { lease.revoke(); write.cancel() }
        try Task.checkCancellation(); try lease.check(); try validate(target, displays: plan.displays)
        if plan.layout == .restore { originals[key] = nil; order.removeAll { $0 == key } }
    }
    private func readChecked(_ target: DesktopWindowTarget, displays: WindowDisplaySnapshot) async throws -> WindowFrame {
        try Task.checkCancellation(); try validate(target, displays: displays)
        let operation = UUID(), readFrame = environment.read, writable = environment.checkWritable
        let read = Task.detached { let frame = try readFrame(target); try Task.checkCancellation(); try writable(target); return frame }
        cancellations[operation] = { read.cancel() }
        defer { cancellations[operation] = nil }
        let frame = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        try Task.checkCancellation(); try validate(target, displays: displays)
        guard frame.valid else { throw WindowLayoutError.unsupported }
        return frame
    }
    private func validate(_ target: DesktopWindowTarget, displays: WindowDisplaySnapshot) throws {
        guard !closed else { throw CancellationError() }
        guard environment.trusted() else { throw DesktopError.accessibilityRequired }
        guard displays.matches(try captureDisplaySnapshot()) else { throw WindowLayoutError.changed }
        try environment.validate(target)
    }
    private func key(for ref: WindowReference) -> UUID {
        if let existing = references.first(where: { $0.value.pid == ref.pid && $0.value.launchDate == ref.launchDate && CFEqual($0.value.element, ref.element) }) { return existing.key }
        let key = UUID(); references[key] = ref; return key
    }
    private func validateRestore(_ plan: PreparedWindowLayout, key: UUID) throws {
        if plan.layout == .restore {
            guard let expected = plan.restoreOperation, originals[key]?.operation == expected else { throw WindowLayoutError.changed }
        }
    }
    private func trimOriginals() {
        while originals.count > 200, let first = order.first(where: { !active.contains($0) }) { originals[first] = nil; order.removeAll { $0 == first } }
        references = references.filter { originals[$0.key] != nil || active.contains($0.key) }
    }
    private static func liveDisplays() -> [DisplayGeometry] {
        let screens = NSScreen.screens, top = screens.first?.frame.maxY ?? 0
        return screens.enumerated().map { index, screen in
            let f = screen.visibleFrame
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? String(index)
            return DisplayGeometry(id: id, visibleFrame: WindowFrame(x: f.minX, y: top-f.maxY, width: f.width, height: f.height))
        }
    }
    nonisolated private static func readFrame(_ ref: WindowReference) throws -> WindowFrame {
        try Task.checkCancellation()
        try validateLiveReference(ref)
        guard let windows = try? AX.boundedWindowElements(AX.application(ref.pid)), windows.contains(where: { CFEqual($0, ref.element) }),
              let p = AX.read(ref.element, kAXPositionAttribute), let s = AX.read(ref.element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw WindowLayoutError.expired }
        var point = CGPoint.zero; var size = CGSize.zero
        let position = p as! AXValue, dimension = s as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(dimension) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(dimension, .cgSize, &size) else { throw WindowLayoutError.unsupported }
        let frame = WindowFrame(x: point.x, y: point.y, width: size.width, height: size.height)
        guard frame.valid else { throw WindowLayoutError.unsupported }; return frame
    }
    nonisolated private static func checkWritable(_ ref: WindowReference) throws {
        try Task.checkCancellation()
        try validateLiveReference(ref)
        var positionWritable = DarwinBoolean(false), sizeWritable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(ref.element, kAXPositionAttribute as CFString, &positionWritable) == .success,
              AXUIElementIsAttributeSettable(ref.element, kAXSizeAttribute as CFString, &sizeWritable) == .success,
              positionWritable.boolValue, sizeWritable.boolValue else { throw WindowLayoutError.unsupported }
    }
    nonisolated private static func writeFrame(_ frame: WindowFrame, expected: WindowFrame, reference ref: WindowReference, lease: DesktopOperationLease, submission: WindowFrameSubmission) throws {
        try lease.check(); try submission.check()
        guard try readFrame(ref).approximatelyEquals(expected) else { throw WindowLayoutError.changed }
        try checkWritable(ref)
        var point = CGPoint(x: frame.x, y: frame.y); var size = CGSize(width: frame.width, height: frame.height)
        guard let position = AXValueCreate(.cgPoint, &point), let dimension = AXValueCreate(.cgSize, &size) else { throw WindowLayoutError.unsupported }
        try submission.check(); try validateLiveReference(ref); try lease.markSubmission(); submission.mark()
        guard AXUIElementSetAttributeValue(ref.element, kAXPositionAttribute as CFString, position) == .success else { throw WindowLayoutError.unsupported }
        try lease.check(); try submission.check(); try validateLiveReference(ref)
        guard AXUIElementSetAttributeValue(ref.element, kAXSizeAttribute as CFString, dimension) == .success else { throw WindowLayoutError.unsupported }
        try submission.check(); try lease.check(); try validateLiveReference(ref)
        guard AXUIElementSetAttributeValue(ref.element, kAXPositionAttribute as CFString, position) == .success,
              try readFrame(ref).approximatelyEquals(frame) else { throw WindowLayoutError.verificationFailed }
    }
    nonisolated private static func validateLiveReference(_ ref: WindowReference) throws {
        guard AXIsProcessTrusted() else { throw DesktopError.accessibilityRequired }
        guard let date = ref.launchDate, let app = NSRunningApplication(processIdentifier: ref.pid), !app.isTerminated,
              app.launchDate == date else { throw WindowLayoutError.expired }
    }
}
