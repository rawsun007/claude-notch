import AppKit
import CoreGraphics

/// Handles Enter / Escape for notch cards.
///
/// The hard part: we must catch Enter/Esc even when ANOTHER app is frontmost,
/// consume them so they don't beep or reach that app, and NOT steal keyboard
/// focus (stealing focus hijacked the user's typing and beeped on stray keys).
///
/// Solution: a CGEventTap (needs Accessibility, which we already require). It
/// sees keys before they reach any app, so it can consume Enter/Esc for a
/// card without us ever becoming the key window. Compose (which needs real
/// typing) is handled by a local monitor while our app is key; the tap passes
/// keys through in that mode. If the tap can't be created we fall back to a
/// non-consuming global monitor.
@MainActor
final class KeyboardMonitor {
    private weak var state: AppState?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// True once the CGEventTap is live — the window controller uses this to
    /// decide whether it still needs to makeKey for non-text cards.
    private(set) var hasEventTap = false

    init(state: AppState) { self.state = state }

    private var retryTimer: Timer?

    func start() {
        stop()
        installEventTap()
        installLocalMonitor()
        if !hasEventTap {
            installGlobalMonitorFallback()
            // The tap fails until Accessibility is trusted (e.g. right after a
            // reinstall changed our signature). Retry so it activates the
            // moment the user re-grants — no relaunch needed.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.hasEventTap else { return }
                    self.installEventTap()
                    if self.hasEventTap {
                        self.dbg("event tap activated on retry")
                        if let g = self.globalMonitor { NSEvent.removeMonitor(g); self.globalMonitor = nil }
                        self.retryTimer?.invalidate(); self.retryTimer = nil
                    }
                }
            }
        }
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes); runLoopSource = nil }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); eventTap = nil }
        hasEventTap = false
    }

    // MARK: - Event tap (global, consuming, no focus steal)

    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mon = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { mon.tapCallback(type: type, event: event) }
            },
            userInfo: ptr
        ) else {
            hasEventTap = false
            dbg("event tap FAILED to create (accessibility not trusted?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
        hasEventTap = true
        dbg("event tap CREATED")
    }

    private func dbg(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/claudenotch-debug.log")
        let line = "[\(Date())] kbd: \(s)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: url) }
    }

    private func tapCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables the tap if our callback ever stalls — re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let state else { return Unmanaged.passUnretained(event) }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasMods = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

        // Global shortcut: ⌘⌥Space — toggle history panel from any app.
        if keyCode == 49,
           flags.contains(.maskCommand), flags.contains(.maskAlternate),
           !flags.contains(.maskControl), !flags.contains(.maskShift) {
            if state.isHistoryOpen {
                state.closeHistory()
            } else if !state.history.isEmpty || !state.sessionHistory.isEmpty {
                state.openHistory()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            return nil
        }

        switch state.mode {
        case .autoInfo:
            if keyCode == 53 { state.dismissAutoInfo(); return nil }
            return Unmanaged.passUnretained(event)
        case .permission, .question, .completed, .responseDetail, .history:
            // Consume ONLY Enter/Esc (so they don't beep / reach the other
            // app). Every other key passes through, so the user keeps typing
            // in whatever app they're in.
            if keyCode == 53 && !hasMods { handleKey(53, command: false); return nil }
            if (keyCode == 36 || keyCode == 76) && !hasMods { handleKey(36, command: false); return nil }
            // ⌘C while the reply detail card is open copies the full reply —
            // the card has no text field, so plain ⌘C would otherwise go to
            // (and possibly beep in) whatever app is frontmost.
            if case .responseDetail = state.mode,
               keyCode == 8, flags.contains(.maskCommand),
               !flags.contains(.maskAlternate), !flags.contains(.maskControl),
               !flags.contains(.maskShift) {
                state.copyDetailResponse()
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            // .compose is handled by the local monitor (typing must reach the
            // TextEditor); idle/thinking pass through.
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Local monitor (compose typing while our app is key)

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let state = self.state else { return event }
                switch state.mode {
                case .compose:
                    if event.keyCode == 53 { self.handleKey(53, command: false); return nil }
                    if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) {
                        self.handleKey(36, command: true); return nil
                    }
                    return event   // let the TextEditor type
                default:
                    // If the tap is handling these we won't get here for Enter/
                    // Esc; if there's no tap, consume so we don't beep.
                    if !self.hasEventTap, self.isCardMode(state.mode),
                       event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
                        self.handleKey(Int(event.keyCode), command: event.modifierFlags.contains(.command))
                        return nil
                    }
                    return event
                }
            }
        }
    }

    private func installGlobalMonitorFallback() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self, let state = self.state else { return }
                if case .autoInfo = state.mode, event.keyCode == 53 { state.dismissAutoInfo(); return }
                if self.isCardMode(state.mode),
                   event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
                    self.handleKey(Int(event.keyCode), command: event.modifierFlags.contains(.command))
                }
            }
        }
    }

    private func isCardMode(_ mode: NotchMode) -> Bool {
        switch mode {
        case .permission, .completed, .question, .compose, .responseDetail, .history: return true
        default: return false
        }
    }

    // MARK: - Resolve

    private func handleKey(_ keyCode: Int, command: Bool) {
        guard let state else { return }
        switch keyCode {
        case 36, 76:                 // Return / Keypad Enter
            switch state.mode {
            case .permission(let req) where req.kind == .toolUse:
                // Dangerous needs hold-to-confirm; a budget block needs an
                // explicit choice (Deny / Allow once / Raise cap), so Enter
                // must not auto-allow either.
                if req.isDangerous || req.budgetBlock != nil { return }
                if state.permissionQueue.count > 1 {
                    state.resolveAllPermissions(.allow)
                } else {
                    state.resolveCurrentPermission(.allow)
                }
            case .permission:
                state.resolveCurrentPermission(.ask)
            case .completed:
                state.dismissCurrentCompleted()
            case .compose:
                state.sendCompose()
            case .responseDetail:
                state.closeResponseDetail()
            case .history:
                state.closeHistory()
            default:
                break
            }
        case 53:                     // Escape
            switch state.mode {
            case .permission(let req) where req.kind == .toolUse:
                state.resolveCurrentPermission(.deny)
            case .permission:
                state.resolveCurrentPermission(.ask)
            case .question:
                state.resolveCurrentQuestion(nil)
            case .completed:
                state.dismissCurrentCompleted()
            case .compose:
                state.cancelCompose()
            case .responseDetail:
                state.closeResponseDetail()
            case .history:
                state.closeHistory()
            case .autoInfo:
                state.dismissAutoInfo()
            default:
                break
            }
        default:
            break
        }
    }
}
