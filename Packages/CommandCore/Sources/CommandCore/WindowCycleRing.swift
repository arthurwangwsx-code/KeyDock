import Foundation

/// 仅保存不透明窗口ID。宿主负责隔离访问、AX权限、真实焦点读回和窗口身份有效性。
public struct WindowCycleRing: Sendable {
    public enum Direction: Equatable, Sendable { case next, previous }

    /// 不能从外部构造或反序列化；一次准备只对应一次确认。
    public struct Transition: Hashable, Sendable {
        public let sourceID: String
        public let targetID: String
        public let generation: UUID
        public let nonce: UUID
        fileprivate init(sourceID: String, targetID: String, generation: UUID) {
            self.sourceID = sourceID; self.targetID = targetID
            self.generation = generation; self.nonce = UUID()
        }
    }

    public static let maximumWindowCount = 128
    public private(set) var windowIDs: [String] = []
    public private(set) var focusedID: String?
    public private(set) var generation = UUID()
    private var pending: Transition?

    public init() {}

    /// 保留存活成员原顺序，新成员按本次输入顺序追加；不采用raise后的前后顺序。
    /// focusedID必须来自本次真实读取；nil/不在快照中表示当前焦点不可确认。
    /// 运行中的外部焦点观察也可调用本方法，从而废弃旧操作的迟到确认。
    public mutating func synchronize(windowIDs observedIDs: [String], focusedID observedFocus: String?) {
        let updated = reconciledIDs(observedIDs, focusedID: observedFocus)
        let confirmedFocus = observedFocus.flatMap { updated.contains($0) ? $0 : nil }
        if updated != windowIDs || confirmedFocus != focusedID {
            generation = UUID()
            pending = nil
        }
        windowIDs = updated
        focusedID = confirmedFocus
    }

    /// 不移动基线；重复准备会以新nonce废弃此前尚未确认的操作。
    public mutating func prepare(direction: Direction, windowIDs: [String], focusedID: String?) -> Transition? {
        synchronize(windowIDs: windowIDs, focusedID: focusedID)
        pending = nil
        guard self.windowIDs.count > 1, let source = self.focusedID,
              let index = self.windowIDs.firstIndex(of: source) else { return nil }
        let count = self.windowIDs.count
        let offset = direction == .next ? 1 : count - 1
        let transition = Transition(sourceID: source, targetID: self.windowIDs[(index + offset) % count], generation: generation)
        pending = transition
        return transition
    }

    /// 宿主可在每次异步等待后、真正AX写入前检查；这不是执行权限授权。
    public func isCurrent(_ transition: Transition) -> Bool {
        pending == transition && transition.generation == generation &&
        focusedID == transition.sourceID && windowIDs.contains(transition.targetID)
    }

    /// 只有当前操作且真实读回目标窗口时才移动基线。失败不推进，旧回执不影响新操作。
    @discardableResult
    public mutating func commit(_ transition: Transition, confirmedFocusedID: String?) -> Bool {
        guard isCurrent(transition) else { return false }
        pending = nil
        guard confirmedFocusedID == transition.targetID else { return false }
        focusedID = transition.targetID
        return true
    }

    /// 明确的AX失败／取消使用此入口；迟到取消不能取消更新的操作。
    @discardableResult
    public mutating func cancel(_ transition: Transition) -> Bool {
        guard isCurrent(transition) else { return false }
        pending = nil
        return true
    }

    /// 用于退出、权限撤销、身份作用域更换；相同文本ID也不能复用旧回执。
    public mutating func reset() {
        windowIDs = []; focusedID = nil; pending = nil; generation = UUID()
    }

    private func reconciledIDs(_ observedIDs: [String], focusedID: String?) -> [String] {
        let previous = Set(windowIDs)
        var surviving = Set<String>(), additions = [String](), added = Set<String>()
        var focusPresent = false
        // 输入只扫描，不另建全量Set；内部临时身份集合均有128条上限。
        for id in observedIDs where !id.isEmpty {
            if id == focusedID { focusPresent = true }
            if previous.contains(id) { surviving.insert(id) }
            else if additions.count < Self.maximumWindowCount, added.insert(id).inserted { additions.append(id) }
        }
        var result = windowIDs.filter { surviving.contains($0) }
        result.append(contentsOf: additions.prefix(Self.maximumWindowCount - result.count))
        // 超限时保留已有存活成员；若真实焦点在范围外，以末位让出一个位置。
        if let focusedID, !focusedID.isEmpty, focusPresent, !result.contains(focusedID) {
            if result.count == Self.maximumWindowCount { result.removeLast() }
            result.append(focusedID)
        }
        return result
    }
}
