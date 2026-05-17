import AppKit

/// Listens for Enter / Escape when a card is showing and the cursor is in
/// the notch hot zone. Only fires under those conditions so it doesn't
/// intercept Enter while the user is typing in their terminal.
@MainActor
final class KeyboardMonitor {
    private weak var state: AppState?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(state: AppState) { self.state = state }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor  { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard let state else { return }
        debugLog("key keyCode=\(event.keyCode) hover=\(state.isHovering) mode=\(state.mode)")

        // For Enter/Esc, drop the hover requirement: if a card is showing,
        // the user clearly meant the keystroke for the notch.
        let cardActive: Bool = {
            switch state.mode {
            case .permission, .completed, .question: return true
            default: return false
            }
        }()

        switch event.keyCode {
        case 36, 76:                 // Return, Keypad Enter
            guard cardActive else { return }
            debugLog("  → ENTER with active card → resolving")
            switch state.mode {
            case .permission(let req) where req.kind == .toolUse:
                state.resolveCurrentPermission(.allow)
            case .permission:
                state.resolveCurrentPermission(.ask)
            case .completed:
                state.dismissCurrentCompleted()
            default:
                break
            }
        case 53:                     // Escape
            guard cardActive else { return }
            debugLog("  → ESC with active card → cancelling")
            switch state.mode {
            case .permission(let req) where req.kind == .toolUse:
                state.resolveCurrentPermission(.deny)
            case .permission:
                state.resolveCurrentPermission(.ask)
            case .question:
                state.resolveCurrentQuestion(nil)
            case .completed:
                state.dismissCurrentCompleted()
            default:
                break
            }
        default:
            break
        }
    }

    private func debugLog(_ msg: String) {
        let url = URL(fileURLWithPath: "/tmp/claudenotch-debug.log")
        let line = "[\(Date())] kbd: \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
