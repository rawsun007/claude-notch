import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let state = OnboardingState()
    weak var appState: AppState?

    private static let userDefaultsKey = "claudenotch.onboardingCompleted"

    /// True once the user has explicitly closed the onboarding window.
    /// Drives the auto-show on first launch.
    static var hasBeenDismissed: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    static func markDismissed() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
    }

    /// Show automatically on launch when either:
    /// - the user has never dismissed onboarding (first run), or
    /// - no agent's hooks are wired up (so the app would be useless).
    ///
    /// Codex counts. `isInstalled` only reads ~/.claude/settings.json, so
    /// someone running ClaudeNotch purely for Codex was told to set up every
    /// single launch, with no way to make it stop.
    static var shouldAutoShow: Bool {
        !hasBeenDismissed || !(HookInstaller.isInstalled || HookInstaller.isCodexInstalled)
    }

    func show() {
        state.appState = appState
        if let existing = window {
            state.startPolling()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: OnboardingView(state: state) { [weak self] in
            self?.close()
        })
        // Track the SwiftUI content's size so the window has no dead space
        // below the steps (the step list grows/shrinks with the jq row and
        // relaunch hints).
        if #available(macOS 13.0, *) {
            host.sizingOptions = [.preferredContentSize]
        }
        let w = NSWindow(contentViewController: host)
        w.title = "ClaudeNotch Setup"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = WindowCloser.shared
        WindowCloser.shared.onClose = { [weak self] in self?.handleUserClose() }

        window = w
        state.startPolling()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        state.stopPolling()
        window?.orderOut(nil)
        // First-completion welcome tour: when the user finishes onboarding for
        // the first time AND the hooks are actually wired, show a sample card
        // so they see what ClaudeNotch looks like right away.
        let isFirstCompletion = !Self.hasBeenDismissed
        Self.markDismissed()
        if isFirstCompletion, HookInstaller.isInstalled || HookInstaller.isCodexInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.appState?.triggerWelcomeDemo()
            }
        }
    }

    private func handleUserClose() {
        state.stopPolling()
        Self.markDismissed()
    }
}

/// NSWindow needs a delegate object — SwiftUI hosting alone won't tell us
/// when the user clicks the red traffic light. This catches that.
private final class WindowCloser: NSObject, NSWindowDelegate {
    static let shared = WindowCloser()
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
