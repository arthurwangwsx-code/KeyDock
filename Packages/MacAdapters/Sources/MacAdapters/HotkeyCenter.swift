import AppKit
import Carbon

public struct HotkeyBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) { self.keyCode = keyCode; self.modifiers = modifiers }
    public var isValid: Bool {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return keyCode <= 127 && modifiers != 0 && modifiers & ~allowed == 0
    }
    public var display: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + (Self.names[keyCode] ?? "[\(keyCode)]")
    }
    public static func from(_ event: NSEvent) -> HotkeyBinding {
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        return HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: flags)
    }
    private static let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space",36:"↩",48:"⇥",51:"⌫",123:"←",124:"→",125:"↓",126:"↑",53:"esc",115:"Home",119:"End",116:"Page Up",121:"Page Down",117:"⌦",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
}

public struct HotkeyRegistrationError: Error, Sendable {
    public let status: OSStatus
    public let restorationFailed: Bool
    public init(status: OSStatus, restorationFailed: Bool = false) { self.status = status; self.restorationFailed = restorationFailed }
}

@MainActor public struct HotkeyDefinition {
    public let id: UInt32
    public let binding: HotkeyBinding
    public let action: @MainActor () -> Void
    public init(id: UInt32, binding: HotkeyBinding, action: @escaping @MainActor () -> Void) {
        self.id = id; self.binding = binding; self.action = action
    }
}

/// 整套配置要么生效，要么恢复旧配置；恢复失败时全停，等待用户重试。
@MainActor public final class HotkeyCenter {
    private enum Mode { case active, recording, unavailable, stopped }
    private let registry: any HotkeyRegistering
    private var definitions: [UInt32: HotkeyDefinition] = [:]
    private var wireToLogical: [UInt32: UInt32] = [:]
    private var nextWireID: UInt32 = 0
    private var mode: Mode = .active
    private var installationError: HotkeyRegistrationError?
    public var activeIDs: Set<UInt32> { Set(wireToLogical.values) }
    public var configuredIDs: Set<UInt32> { Set(definitions.keys) }
    public var isUnavailable: Bool { mode == .unavailable }

    public init(registry: (any HotkeyRegistering)? = nil) {
        self.registry = registry ?? CarbonHotkeyRegistry()
        do {
            try installReceiver()
        } catch { installationError = Self.registrationError(error); mode = .unavailable }
    }

    /// 兼容原单项 API；生产宿主使用 replace 一次提交整套，支持交换两个绑定。
    public func set(id: UInt32, binding: HotkeyBinding?, action: @escaping @MainActor () -> Void) throws {
        var next = definitions
        next[id] = binding.map { HotkeyDefinition(id: id, binding: $0, action: action) }
        try replace(Array(next.values))
    }

    public func replace(_ next: [HotkeyDefinition]) throws {
        guard mode != .stopped, mode != .recording else { throw HotkeyRegistrationError(status: OSStatus(paramErr)) }
        guard Set(next.map(\.id)).count == next.count,
              Set(next.map(\.binding)).count == next.count,
              next.allSatisfy({ Self.valid($0.binding) }) else {
            throw HotkeyRegistrationError(status: OSStatus(eventHotKeyExistsErr))
        }
        if !next.isEmpty { try ensureReceiver() }
        let previous = definitions
        clearActive()
        do {
            let mapping = try register(next)
            definitions = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
            wireToLogical = mapping; mode = .active
        } catch {
            let failure = Self.registrationError(error)
            do {
                wireToLogical = try register(Array(previous.values)); mode = .active
            } catch {
                wireToLogical = [:]; mode = .unavailable
                throw HotkeyRegistrationError(status: failure.status, restorationFailed: true)
            }
            throw failure
        }
    }

    public func suspend() {
        guard mode != .stopped, mode != .recording else { return }
        clearActive(); mode = .recording
    }
    public func resume() throws {
        guard mode != .stopped else { throw HotkeyRegistrationError(status: OSStatus(paramErr)) }
        guard mode != .active else { return }
        if !definitions.isEmpty { try ensureReceiver() }
        do { wireToLogical = try register(Array(definitions.values)); mode = .active }
        catch { wireToLogical = [:]; mode = .unavailable; throw Self.registrationError(error) }
    }
    /// 当前保存配置无法恢复时必须禁用旧/新方案，不能让错误方案继续触发。
    public func invalidate() {
        guard mode != .stopped else { return }
        clearActive(); mode = .unavailable
    }
    public func shutdown() {
        guard mode != .stopped else { return }
        clearActive(); definitions = [:]; mode = .stopped; registry.shutdown()
    }

    private func installReceiver() throws {
        try registry.install { [weak self] event in
            Task { @MainActor [weak self] in self?.dispatch(event) }
        }
    }
    private func ensureReceiver() throws {
        guard installationError != nil else { return }
        do { try installReceiver(); installationError = nil }
        catch { installationError = Self.registrationError(error); mode = .unavailable; throw error }
    }
    private func dispatch(_ event: HotkeyEvent) {
        guard mode == .active, event.signature == HotkeyEvent.keyDockSignature,
              let logicalID = wireToLogical[event.id] else { return }
        definitions[logicalID]?.action()
    }
    private func register(_ entries: [HotkeyDefinition]) throws -> [UInt32: UInt32] {
        var registered: [UInt32: UInt32] = [:]
        do {
            for entry in entries.sorted(by: { $0.id < $1.id }) {
                // 不循环使用 token；排队的 OS 事件和 Swift Task 永远无法借用新 handler。
                guard nextWireID < UInt32.max else { throw HotkeyRegistrationError(status: OSStatus(paramErr)) }
                nextWireID += 1
                try registry.register(id: nextWireID, binding: entry.binding)
                registered[nextWireID] = entry.id
            }
            return registered
        } catch {
            for wireID in registered.keys { registry.unregister(id: wireID) }
            throw error
        }
    }
    private func clearActive() {
        let old = wireToLogical; wireToLogical = [:]
        for wireID in old.keys { registry.unregister(id: wireID) }
    }
    private static func valid(_ binding: HotkeyBinding) -> Bool {
        binding.isValid
    }
    private static func registrationError(_ error: any Error) -> HotkeyRegistrationError {
        error as? HotkeyRegistrationError ?? HotkeyRegistrationError(status: OSStatus(paramErr))
    }
}
