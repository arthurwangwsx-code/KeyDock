import AppKit
import Carbon

public struct HotkeyBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey)) { self.keyCode = keyCode; self.modifiers = modifiers }
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
    private static let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space",36:"↩",48:"⇥",51:"⌫",123:"←",124:"→",125:"↓",126:"↑"]
}

public struct HotkeyRegistrationError: Error, Sendable { public let status: OSStatus }

@MainActor public final class HotkeyCenter {
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var bindings: [UInt32: HotkeyBinding] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var installationStatus: OSStatus = noErr
    private var suspended = false
    public var activeIDs: Set<UInt32> { Set(registrations.keys) }
    public var configuredIDs: Set<UInt32> { Set(bindings.keys) }
    public init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        installationStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            let keyID = id.id
            Task { @MainActor in if !center.suspended { center.handlers[keyID]?() } }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
    public func set(id: UInt32, binding: HotkeyBinding?, action: @escaping @MainActor () -> Void) throws {
        guard installationStatus == noErr, eventHandler != nil else { throw HotkeyRegistrationError(status: installationStatus == noErr ? OSStatus(paramErr) : installationStatus) }
        let old = bindings[id]
        if let other = bindings.first(where: { $0.key != id && $0.value == binding }) { _ = other; throw HotkeyRegistrationError(status: OSStatus(eventHotKeyExistsErr)) }
        if let ref = registrations.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        guard let binding else { bindings[id] = nil; handlers[id] = nil; return }
        if suspended { bindings[id] = binding; handlers[id] = action; return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x4B444F43, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            if let old {
                var restored: EventHotKeyRef?
                if RegisterEventHotKey(old.keyCode, old.modifiers, EventHotKeyID(signature: 0x4B444F43, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &restored) == noErr { registrations[id] = restored }
                else { bindings[id] = nil; handlers[id] = nil }
            }
            throw HotkeyRegistrationError(status: status)
        }
        registrations[id] = ref; bindings[id] = binding; handlers[id] = action
    }
    public func suspend() {
        guard !suspended else { return }
        suspended = true
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        registrations.removeAll()
    }
    public func resume() throws {
        guard suspended else { return }
        suspended = false
        var firstFailure: OSStatus?
        for (id, binding) in bindings {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x4B444F43, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref { registrations[id] = ref }
            else if firstFailure == nil { firstFailure = status }
        }
        if let firstFailure { throw HotkeyRegistrationError(status: firstFailure) }
    }
    public func shutdown() {
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        registrations.removeAll(); bindings.removeAll(); handlers.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
    }
}
