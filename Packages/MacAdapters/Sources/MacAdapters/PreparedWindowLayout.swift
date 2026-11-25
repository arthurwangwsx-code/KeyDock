import AppKit
import CommandCore

/// 仅在本次controller生命周期内有效；屏幕编号和拓扑不进入持久档案。
public struct WindowDisplaySnapshot: Sendable {
    public let displays: [DisplayGeometry]
    public var primaryDisplayID: String? { displays.first?.id }
    let owner: UUID
    let generation: UUID
    init(displays: [DisplayGeometry], owner: UUID, generation: UUID) {
        self.displays = displays; self.owner = owner; self.generation = generation
    }
    func matches(_ other: Self) -> Bool {
        owner == other.owner && generation == other.generation && displays.count == other.displays.count
            && zip(displays, other.displays).allSatisfy { $0.id == $1.id && $0.visibleFrame == $1.visibleFrame }
    }
}

/// 冻结原对象与两组frame。新lease也不能重放已消费计划；不公开可伪造的初始化入口。
public final class PreparedWindowLayout: @unchecked Sendable {
    public let originalFrame: WindowFrame
    public let destinationFrame: WindowFrame
    public let target: DesktopWindowTarget
    let displays: WindowDisplaySnapshot
    let layout: WindowLayout
    let restoreOperation: UUID?
    private let lock = NSLock()
    private var consumed = false
    init(target: DesktopWindowTarget, original: WindowFrame, destination: WindowFrame, displays: WindowDisplaySnapshot, layout: WindowLayout, restoreOperation: UUID?) {
        self.target = target; originalFrame = original; destinationFrame = destination; self.displays = displays; self.layout = layout
        self.restoreOperation = restoreOperation
    }
    func claim() throws {
        lock.lock(); defer { lock.unlock() }
        guard !consumed else { throw DesktopOperationLeaseError.alreadyUsed }
        consumed = true
    }
}

/// frame提交与同lease中的应用激活分开判断，避免未布局就污染Restore基线。
final class WindowFrameSubmission: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = false
    private let checkFocus: @Sendable () throws -> Void
    private let isCurrent: @Sendable () -> Bool
    init(checkFocus: @escaping @Sendable () throws -> Void = {}, isCurrent: @escaping @Sendable () -> Bool = { true }) { self.isCurrent = isCurrent; self.checkFocus = checkFocus }
    var didSubmit: Bool { lock.lock(); defer { lock.unlock() }; return submitted }
    func mark() { lock.lock(); submitted = true; lock.unlock() }
    func check() throws { try Task.checkCancellation(); guard isCurrent() else { throw WindowLayoutError.changed }; try checkFocus() }
}

/// 生产适配与合成测试共用状态机；合成端口不发送AX或进程请求。
@MainActor struct WindowLayoutEnvironment {
    var trusted: () -> Bool
    var validate: (DesktopWindowTarget) throws -> Void
    var displays: () -> (UUID, [DisplayGeometry])
    var generationIsCurrent: @Sendable (UUID) -> Bool
    var read: @Sendable (DesktopWindowTarget) throws -> WindowFrame
    var checkWritable: @Sendable (DesktopWindowTarget) throws -> Void
    var write: @Sendable (WindowFrame, WindowFrame, DesktopWindowTarget, DesktopOperationLease, WindowFrameSubmission) throws -> Void
    var checkFocused: @Sendable (DesktopWindowTarget) throws -> Void = { _ in }
}

/// 几何恢复为相同字节也不能让断开后重连的旧计划再次生效。
final class WindowDisplayGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.lock.lock(); self.value = UUID(); self.lock.unlock()
        }
    }
    var current: UUID { lock.lock(); defer { lock.unlock() }; return value }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
