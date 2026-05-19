import AppKit
import SwiftUI
import Combine

/// NSPanel that:
///   - refuses to be auto-constrained to the visible area (so we can overlap
///     the physical notch / menu-bar region),
///   - can become key when asked, so our local NSEvent monitor receives
///     keystrokes (no permission needed when the panel is key),
///   - never becomes main (we don't want a dock entry).
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchWindowController {
    let state: AppState
    let window: NotchPanel
    private var cancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state

        let size = NotchView.collapsedSize(on: NSScreen.main)
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isFloatingPanel = true
        // false → panel can become key on demand (not just when a key view
        // requires it). We use this to grab keystrokes for Enter/Escape.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true

        let host = NSHostingView(rootView: NotchView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        // Macos 13.3+: report the SwiftUI content's intrinsic size so
        // host.fittingSize is the *real* height our content needs. We use
        // that to size the panel in relayout(), avoiding any drift between
        // the formula in NotchView.size() and what SwiftUI actually draws.
        if #available(macOS 13.3, *) {
            host.sizingOptions = [.intrinsicContentSize]
        }
        panel.contentView = host

        self.window = panel

        // Re-layout whenever the mode OR the hover state changes. Also grab
        // key focus when an interactive card appears so the local key monitor
        // can receive Enter / Escape.
        cancellable = Publishers.CombineLatest(state.$mode, state.$isHovering)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, _ in
                guard let self else { return }
                // First pass: formula-based size so the panel is visible
                // immediately. Second pass (next runloop tick): SwiftUI has
                // now rendered the new mode, so host.fittingSize is the
                // true content height — re-snap the window to that.
                self.relayout(animated: true)
                DispatchQueue.main.async { self.relayout(animated: true) }
                switch mode {
                case .permission, .question, .completed, .compose, .history, .responseDetail:
                    self.window.makeKey()
                default:
                    break
                }
            }
    }

    func show() {
        logScreenGeometry()
        relayout(animated: false)
        window.orderFrontRegardless()
    }

    private func logScreenGeometry() {
        var lines: [String] = ["--- ClaudeNotch geometry @ \(Date()) ---"]
        for (i, screen) in NSScreen.screens.enumerated() {
            let main = screen == NSScreen.main ? " (main)" : ""
            lines.append("screen[\(i)]\(main):")
            lines.append("  frame=\(screen.frame)")
            lines.append("  visibleFrame=\(screen.visibleFrame)")
            lines.append("  safeAreaInsets.top=\(screen.safeAreaInsets.top)")
            lines.append("  auxiliaryTopLeftArea=\(String(describing: screen.auxiliaryTopLeftArea))")
            lines.append("  auxiliaryTopRightArea=\(String(describing: screen.auxiliaryTopRightArea))")
            let collapsed = NotchView.collapsedSize(on: screen)
            lines.append("  collapsedSize=\(collapsed)")
        }
        debugAppend(lines.joined(separator: "\n") + "\n")
    }

    private func debugAppend(_ text: String) {
        let url = URL(fileURLWithPath: "/tmp/claudenotch-debug.log")
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    private func relayout(animated: Bool) {
        let screen = currentScreen()
        let formula = NotchView.size(for: state.mode, hovering: state.isHovering, on: screen)
        // Ask SwiftUI what it actually wants. fittingSize returns the size
        // the hosting view would adopt to fit its intrinsic content (the
        // .frame(width:).fixedSize(vertical:) on NotchView's root). This
        // is the *true* card height — it can differ from the formula by
        // a few points either way, and trusting it eliminates dead space.
        var size = formula
        if let host = window.contentView {
            let fit = host.fittingSize
            // Only trust the measured height if SwiftUI has already rendered
            // the new mode — we detect that by checking the width matches.
            // On the first relayout after a mode switch, fit.width is still
            // the previous mode's width; we fall back to the formula then,
            // and the deferred second relayout picks up the correct size.
            let widthMatches = abs(fit.width - formula.width) < 1
            if widthMatches, fit.height > 0 {
                let screenCap = screen.frame.height * 0.92
                size = CGSize(width: formula.width, height: min(fit.height, screenCap))
            }
        }
        let s = screen.frame
        let centerX: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return (left.maxX + right.minX) / 2
            }
            return s.midX
        }()
        let frame = NSRect(
            x: centerX - size.width / 2,
            y: s.maxY - size.height,
            width: size.width,
            height: size.height
        )
        debugAppend("relayout: mode=\(state.mode) hover=\(state.isHovering) formula=\(formula) measured=\(window.contentView?.fittingSize ?? .zero) → size=\(size) frame=\(frame) screen.maxY=\(s.maxY)\n")

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26
                // Snappy at start, gentle settle — close to iOS Dynamic Island.
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1.0, 0.5, 1.0)
                ctx.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
}
