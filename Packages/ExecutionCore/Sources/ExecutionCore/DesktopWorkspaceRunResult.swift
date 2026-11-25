import Foundation

/// unrecorded仅用于崩溃恢复：缺少回执不等于从未执行。
public enum DesktopWorkspacePhaseResult: String, Codable, Sendable { case notExecuted, notRequired, confirmed, declined, unknown, unrecorded }
public enum DesktopWorkspaceStopReason: String, Codable, Sendable { case completed, failed, cancelled }
public struct DesktopWorkspaceEntryResult: Codable, Sendable, Equatable {
    public let entryID: UUID
    public var launch: DesktopWorkspacePhaseResult
    public var focus: DesktopWorkspacePhaseResult
    public var layout: DesktopWorkspacePhaseResult
    public init(entryID: UUID, launch: DesktopWorkspacePhaseResult = .notExecuted, focus: DesktopWorkspacePhaseResult = .notExecuted, layout: DesktopWorkspacePhaseResult = .notExecuted) {
        self.entryID = entryID; self.launch = launch; self.focus = focus; self.layout = layout
    }
    public subscript(_ phase: DesktopWorkspaceReceiptPhase) -> DesktopWorkspacePhaseResult {
        get { switch phase { case .launch: launch; case .focus: focus; case .layout: layout } }
        set { switch phase { case .launch: launch = newValue; case .focus: focus = newValue; case .layout: layout = newValue } }
    }
}
/// 父回执保存完整有序结果，child裁剪后仍保留确定事实。不含名称、路径、PID或窗口元数据。
public struct DesktopWorkspaceRunResult: Codable, Sendable, Equatable {
    public var entries: [DesktopWorkspaceEntryResult]
    public var stop: DesktopWorkspaceStopReason
    public var receiptUncertain: Bool
    public init(entryIDs: [UUID], stop: DesktopWorkspaceStopReason = .failed, receiptUncertain: Bool = false) {
        entries = entryIDs.map { .init(entryID: $0) }; self.stop = stop; self.receiptUncertain = receiptUncertain
    }
    public var state: ExecutionState {
        let phases = entries.flatMap { [$0.launch, $0.focus, $0.layout] }
        if receiptUncertain || phases.contains(.unknown) || phases.contains(.unrecorded) { return .interrupted }
        if !entries.isEmpty && entries.allSatisfy({ $0.layout == .confirmed }) { return .succeeded }
        if phases.contains(.confirmed) { return .interrupted }
        return stop == .cancelled ? .cancelled : .failed
    }
    public func validate(manifest: DesktopWorkspaceRunContext?) throws {
        guard let manifest, entries.map(\.entryID) == manifest.entryIDs,
              entries.allSatisfy({ $0.focus != .notRequired && $0.layout != .notRequired }) else { throw InvocationStoreError.invalidMetadata }
    }
    public static func recover(parent: InvocationReceipt, children: [InvocationReceipt]) -> Self? {
        guard let manifest = parent.desktopWorkspaceRun else { return nil }
        if let result = parent.desktopWorkspaceResult { return result }
        var result = Self(entryIDs: manifest.entryIDs, receiptUncertain: true)
        for i in result.entries.indices {
            result.entries[i].launch = .unrecorded; result.entries[i].focus = .unrecorded; result.entries[i].layout = .unrecorded
        }
        for child in children {
            guard let context = child.desktopWorkspace, context.parentID == parent.id,
                  result.entries.indices.contains(context.entryIndex), result.entries[context.entryIndex].entryID == context.entryID else { continue }
            let matches = children.filter { $0.desktopWorkspace == context }
            // 重复阶段不选择较新值冒充可靠结果。
            let fact: DesktopWorkspacePhaseResult
            if matches.count != 1 { fact = .unknown }
            else if child.message == "invocation.notDispatched" || child.message == "workspace.notExecuted" { fact = .notExecuted }
            else if child.state == .succeeded && child.message == "workspace.confirmed" { fact = .confirmed }
            else if child.state == .failed && child.message == "workspace.declined" { fact = .declined }
            else { fact = .unknown }
            result.entries[context.entryIndex][context.phase] = fact
        }
        return result
    }
}
