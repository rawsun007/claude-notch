import AppKit
import Carbon.HIToolbox

/// Registers a global hotkey via the Carbon HotKey API (the modern equivalent —
/// there is no public Cocoa API for system-wide shortcuts). Multiple instances
/// are supported: each gets its own id, and a single shared Carbon event handler
/// routes a firing to the matching instance's `onFire`.
///
/// ⌥⌘N focuses the notch into compose; ⌥⌘, opens settings. Both avoid Spotlight
/// (⌘Space) and the plain ⌘, that each app reserves for its own preferences.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// Action to run when this hotkey fires. Set before registering.
    var onFire: (() -> Void)?

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    private static var nextID: UInt32 = 1
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?

    init() {
        id = GlobalHotkey.nextID
        GlobalHotkey.nextID += 1
    }

    func registerDefault() {
        // ⌥⌘N — kVK_ANSI_N = 45, cmd + option modifiers.
        register(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey))
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        GlobalHotkey.installHandlerIfNeeded()
        GlobalHotkey.handlers[id] = { [weak self] in self?.onFire?() }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("CNCH"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("ClaudeNotch: hotkey registration failed (status=\(status))")
            GlobalHotkey.handlers[id] = nil
        }
    }

    /// Install the one shared Carbon event handler. It reads the fired hotkey's
    /// id off the event and dispatches to the matching instance.
    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                var hkID = EventHotKeyID()
                if let eventRef {
                    GetEventParameter(
                        eventRef,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hkID
                    )
                }
                let fired = hkID.id
                Task { @MainActor in GlobalHotkey.handlers[fired]?() }
                return noErr
            },
            1, &eventType, nil, &eventHandler
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        GlobalHotkey.handlers[id] = nil
    }

    private func fourCharCode(_ s: String) -> OSType {
        var result: OSType = 0
        for c in s.unicodeScalars.prefix(4) {
            result = (result << 8) + OSType(c.value & 0xff)
        }
        return result
    }
}
