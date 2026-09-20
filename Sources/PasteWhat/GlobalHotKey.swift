import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey {
    private static var nextIdentifier: UInt32 = 0
    private var registration: HotKeyRegistration?
    private var generation: UInt32 = 0
    private var handler: (@MainActor () -> Void)?

    func register(keyCode: UInt32 = 9, modifiers: UInt32 = UInt32(optionKey | shiftKey),
                  handler: @escaping @MainActor () -> Void) throws {
        unregister()
        Self.nextIdentifier &+= 1
        generation = Self.nextIdentifier
        let generation = generation
        let box = HotKeyCallbackBox(identifier: generation) { [weak self] identifier in
            guard let self, self.generation == identifier, self.registration != nil else { return }
            self.handler?()
        }
        let opaqueBox = Unmanaged.passRetained(box).toOpaque()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var eventHandler: EventHandlerRef?
        let installation = InstallEventHandler(GetApplicationEventTarget(), pasteWhatHotKeyCallback, 1,
                                               &event, opaqueBox, &eventHandler)
        guard installation == noErr, let eventHandler else {
            Unmanaged<HotKeyCallbackBox>.fromOpaque(opaqueBox).release()
            throw GlobalHotKeyError(status: installation)
        }
        var key: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x50535748, id: generation),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &key)
        guard status == noErr, let key else {
            RemoveEventHandler(eventHandler)
            Unmanaged<HotKeyCallbackBox>.fromOpaque(opaqueBox).release()
            throw GlobalHotKeyError(status: status)
        }
        self.handler = handler
        registration = HotKeyRegistration(key: UInt(bitPattern: key), eventHandler: UInt(bitPattern: eventHandler),
                                          callbackBox: UInt(bitPattern: opaqueBox))
    }

    func unregister() {
        registration?.remove()
        registration = nil
        handler = nil
        generation &+= 1
    }

    deinit {
        // The retained callback box outlives the Carbon registration, even if this owner is released off-main.
        if let registration { DispatchQueue.main.async { registration.remove() } }
    }
}

struct GlobalHotKeyError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if status == eventHotKeyExistsErr { return "此快捷键已被其他应用使用，请选择另一个组合" }
        return "无法注册全局快捷键（\(status)），仍可点击菜单栏图标打开"
    }
}

private final class HotKeyCallbackBox: Sendable {
    let identifier: UInt32
    let fire: @MainActor @Sendable (UInt32) -> Void
    init(identifier: UInt32, fire: @escaping @MainActor @Sendable (UInt32) -> Void) {
        self.identifier = identifier
        self.fire = fire
    }
}

// Storing opaque handles as values lets destruction enqueue cleanup without moving borrowed Carbon objects.
private struct HotKeyRegistration: Sendable {
    let key: UInt
    let eventHandler: UInt
    let callbackBox: UInt

    @MainActor func remove() {
        if let key = EventHotKeyRef(bitPattern: key) { UnregisterEventHotKey(key) }
        if let handler = EventHandlerRef(bitPattern: eventHandler) { RemoveEventHandler(handler) }
        if let pointer = UnsafeMutableRawPointer(bitPattern: callbackBox) {
            Unmanaged<HotKeyCallbackBox>.fromOpaque(pointer).release()
        }
    }
}

private let pasteWhatHotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == 0x50535748 else { return OSStatus(eventNotHandledErr) }
    let box = Unmanaged<HotKeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()
    guard identifier.id == box.identifier else { return OSStatus(eventNotHandledErr) }
    let generation = identifier.id
    Task { @MainActor in box.fire(generation) }
    return noErr
}
