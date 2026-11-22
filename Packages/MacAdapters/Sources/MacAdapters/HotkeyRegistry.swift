import AppKit
import Carbon

public struct HotkeyEvent: Sendable {
    public static let keyDockSignature: UInt32 = 0x4B444F43
    public let signature: UInt32
    public let id: UInt32
    public init(signature: UInt32 = keyDockSignature, id: UInt32) { self.signature = signature; self.id = id }
}

/// ID 是每次注册都更新的传输 token，不是持久命令 ID。
@MainActor public protocol HotkeyRegistering: AnyObject {
    func install(receiver: @escaping @Sendable (HotkeyEvent) -> Void) throws
    func register(id: UInt32, binding: HotkeyBinding) throws
    func unregister(id: UInt32)
    func shutdown()
}

/// 只封装 Carbon 注册，不生成或注入输入事件。
@MainActor final class CarbonHotkeyRegistry: HotkeyRegistering {
    private final class ReceiverBox {
        let receive: @Sendable (HotkeyEvent) -> Void
        init(_ receive: @escaping @Sendable (HotkeyEvent) -> Void) { self.receive = receive }
    }
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var receiver: ReceiverBox?

    func install(receiver: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        guard handler == nil else { throw HotkeyRegistrationError(status: OSStatus(paramErr)) }
        let box = ReceiverBox(receiver); self.receiver = box
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            guard id.signature == HotkeyEvent.keyDockSignature else { return OSStatus(eventNotHandledErr) }
            let box = Unmanaged<ReceiverBox>.fromOpaque(context).takeUnretainedValue()
            box.receive(HotkeyEvent(signature: id.signature, id: id.id))
            return noErr
        }, 1, &event, Unmanaged.passUnretained(box).toOpaque(), &handler)
        guard status == noErr, handler != nil else {
            if let handler { RemoveEventHandler(handler) }; handler = nil
            self.receiver = nil
            throw HotkeyRegistrationError(status: status == noErr ? OSStatus(paramErr) : status)
        }
    }
    func register(id: UInt32, binding: HotkeyBinding) throws {
        guard references[id] == nil, handler != nil else { throw HotkeyRegistrationError(status: OSStatus(paramErr)) }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
            EventHotKeyID(signature: HotkeyEvent.keyDockSignature, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw HotkeyRegistrationError(status: status == noErr ? OSStatus(paramErr) : status) }
        references[id] = reference
    }
    func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }
    func shutdown() {
        for id in Array(references.keys) { unregister(id: id) }
        if let handler { RemoveEventHandler(handler) }; handler = nil; receiver = nil
    }
}
