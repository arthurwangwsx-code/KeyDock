import Foundation
import KeyDockUI

/// 只携带几何需要的计数与身份；不含查询正文、目标或执行授权。
public struct LauncherLayoutSnapshot: Equatable, Sendable {
    public enum Mode: String, Sendable { case search, compactAI }
    public let mode: Mode
    public let modeRevision: UInt64
    public let queryID: UUID?
    public let generation: UInt64
    public let resultCount: Int?
    public let isComplete: Bool
    public let noticeSlots: Int
    public let held: Bool
    public init(mode: Mode, modeRevision: UInt64, queryID: UUID?, generation: UInt64, resultCount: Int? = nil, isComplete: Bool = false, noticeSlots: Int = 0, held: Bool = false) {
        self.mode = mode; self.modeRevision = modeRevision; self.queryID = queryID; self.generation = generation
        self.resultCount = resultCount; self.isComplete = isComplete; self.noticeSlots = noticeSlots; self.held = held
    }
}

/// 每次展示独占；只对已接受批次计算尺寸，异步待定阶段保持现高。
public enum LauncherLayoutDecision: Equatable, Sendable { case rejected, held, place(CGFloat) }

public enum LauncherLayoutMetrics {
    public static let chromeHeight = KDTokens.searchHeight + 28 + KDTokens.footerHeight + 2
    public static func noticeViewportHeight(availableHeight: CGFloat, slots: Int) -> CGFloat {
        guard availableHeight.isFinite, (0...3).contains(slots) else { return 0 }
        return min(CGFloat(slots) * KDTokens.launcherNoticeHeight, max(0, availableHeight-chromeHeight))
    }
}

public struct LauncherLayoutState: Sendable {
    public private(set) var currentHeight = KDTokens.launcherHeight
    private var modeRevision: UInt64?
    private var generation: UInt64?
    private var queryID: UUID?
    private var noticeSlots = 0
    private var searchBaseHeight = KDTokens.launcherHeight
    public init(initialHeight: CGFloat = KDTokens.launcherHeight) {
        let height = initialHeight.isFinite && initialHeight > 0 ? initialHeight : KDTokens.launcherHeight
        currentHeight = height; searchBaseHeight = height
    }
    public mutating func reset(initialHeight: CGFloat = KDTokens.launcherHeight) { self = .init(initialHeight: initialHeight) }
    public mutating func synchronizeActualHeight(_ height: CGFloat) {
        if height.isFinite && height > 0 { currentHeight = height }
    }
    public mutating func resolve(_ snapshot: LauncherLayoutSnapshot, maximumHeight: CGFloat) -> LauncherLayoutDecision {
        guard maximumHeight.isFinite, maximumHeight > 0, (0...3).contains(snapshot.noticeSlots),
              snapshot.resultCount.map({ $0 >= 0 && snapshot.queryID != nil }) ?? !snapshot.isComplete,
              modeRevision.map({ snapshot.modeRevision >= $0 }) ?? true,
              generation.map({ snapshot.generation >= $0 }) ?? true else { return .rejected }
        if snapshot.generation == generation, snapshot.queryID != queryID { return .rejected }
        modeRevision = snapshot.modeRevision; generation = snapshot.generation; queryID = snapshot.queryID
        guard !snapshot.held else { return .held }
        let maximum = min(KDTokens.launcherHeight, maximumHeight)
        var target: CGFloat
        if snapshot.mode == .compactAI { target = maximum }
        else if let count = snapshot.resultCount {
            let boundedCount = min(count, 7)
            let rows: CGFloat = boundedCount == 0 ? 160 : CGFloat(boundedCount) * KDTokens.rowHeight + CGFloat(max(0, boundedCount-1)) * 2 + 5
            let base = max(220, LauncherLayoutMetrics.chromeHeight + rows)
            if snapshot.isComplete { searchBaseHeight = base; noticeSlots = snapshot.noticeSlots }
            else { searchBaseHeight = max(searchBaseHeight, base); noticeSlots = max(noticeSlots, snapshot.noticeSlots) }
            let desired = searchBaseHeight + CGFloat(noticeSlots) * KDTokens.launcherNoticeHeight
            target = snapshot.isComplete ? desired : max(currentHeight, desired)
        } else {
            noticeSlots = max(noticeSlots, snapshot.noticeSlots)
            target = max(currentHeight, searchBaseHeight + CGFloat(noticeSlots) * KDTokens.launcherNoticeHeight)
        }
        target = min(maximum, target)
        currentHeight = target
        return .place(target)
    }
}

public enum LauncherFrameGeometry {
    /// 只改变高度与必要的y夹紧；拖动后的当前顶部自然成为新锚点。
    public static func resized(_ frame: CGRect, height: CGFloat, visibleFrame: CGRect) -> CGRect? {
        let values = [frame.minX, frame.minY, frame.width, frame.height, height, visibleFrame.minX, visibleFrame.minY, visibleFrame.width, visibleFrame.height]
        guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0, height > 0,
              visibleFrame.width > 48, visibleFrame.height > 48 else { return nil }
        let usable = visibleFrame.insetBy(dx: 24, dy: 24), bounded = min(height, usable.height)
        let top = min(usable.maxY, max(frame.maxY, usable.minY + bounded))
        return CGRect(x: frame.minX, y: top-bounded, width: frame.width, height: bounded)
    }
}

