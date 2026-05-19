import AppKit
import Carbon.HIToolbox

/// Registers a single global hotkey via the Carbon HotKey API (the modern
/// equivalent — there is no public Cocoa API for system-wide shortcuts).
/// Default binding is ⌥⌘N — picked to avoid Spotlight (⌘Space) and the
/// many ⌘⇧X system shortcuts. Override via `register(keyCode:modifiers:)`.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// Action to run when the hotkey fires. Set this before registering.
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func registerDefault() {
        // ⌥⌘N — kVK_ANSI_N = 45, cmd + option modifiers.
        register(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey))
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                // Forward to the singleton's onFire. We don't use the
                // hotKeyID — there's only one.
                Task { @MainActor in
                    GlobalHotkey.shared.onFire?()
                }
                return noErr
            },
            1, &eventType, nil, &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: fourCharCode("CNCH"), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("ClaudeNotch: hotkey registration failed (status=\(status))")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
    }

    private func fourCharCode(_ s: String) -> OSType {
        var result: OSType = 0
        for c in s.unicodeScalars.prefix(4) {
            result = (result << 8) + OSType(c.value & 0xff)
        }
        return result
    }
}
