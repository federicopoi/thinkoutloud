import AppKit
import Carbon
import DictationCore

final class HotkeyManager {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current: Shortcut?
    private let onPress: () -> Void
    private static var nextID: UInt32 = 0
    private let identifier: UInt32

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        Self.nextID += 1
        identifier = Self.nextID
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x4C446943, id.id == manager.identifier else { return OSStatus(eventNotHandledErr) }
            manager.onPress()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: Shortcut) throws {
        guard shortcut.isValid else { throw DictationError.message("Use Shift + Space, or a key with Control, Option or Command.") }
        try registerUnchecked(shortcut)
    }

    // Plain Space is reserved only for the lifetime of an active recording.
    func registerRecordingStop() throws {
        try registerUnchecked(Shortcut(keyCode: 49, modifiers: 0, label: "Space"))
    }

    private func registerUnchecked(_ shortcut: Shortcut) throws {
        if current == shortcut { return }
        var replacement: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x4C446943, id: identifier)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &replacement)
        guard result == noErr else { throw DictationError.message("That shortcut is already in use or unavailable. Choose another combination. Your previous shortcut still works.") }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = replacement
        current = shortcut
    }

    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

extension Shortcut {
    static func from(_ event: NSEvent) -> Shortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃ " }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥ " }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧ " }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘ " }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        label += names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }
}
