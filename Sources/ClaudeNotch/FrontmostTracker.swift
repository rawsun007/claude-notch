import Foundation
import AppKit

// Remembers which app you were in before the notch took focus, so it can be handed back.

@MainActor
final class FrontmostTracker {
    private(set) var lastNonSelf: NSRunningApplication?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app else { return }
                let me = Bundle.main.bundleIdentifier
                let bid = app.bundleIdentifier
                guard bid != me else { return }
                // Skip system stuff that flashes through.
                let skip: Set<String> = ["com.apple.WindowManager", "com.apple.dock", "com.apple.notificationcenterui"]
                if let bid, skip.contains(bid) { return }
                self.lastNonSelf = app
            }
        }
        // Seed with the currently frontmost app
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastNonSelf = app
        }
    }

    func activateLastApp() {
        if let app = lastNonSelf, !app.isTerminated {
            AppActivation.bringToFront(app)
            return
        }
        let bundles = [
            "com.anthropic.claudefordesktop",
            "com.todesktop.230313mzl4w4u92",   // Cursor
            "com.microsoft.VSCode",
            "com.googlecode.iterm2",
            "com.apple.Terminal"
        ]
        for b in bundles {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                AppActivation.bringToFront(app)
                return
            }
        }
    }
}

/// Centralised app-activation that works across macOS versions.
/// `.activateIgnoringOtherApps` is deprecated on macOS 14+ and no longer
/// reliable; the parameterless `.activate()` replaces it. We also unhide
/// first — a minimized app otherwise just bounces the Dock icon without
/// surfacing a window.
enum AppActivation {
    static func bringToFront(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        // `.activateIgnoringOtherApps` is deprecated on macOS 14+, but the
        // parameterless replacement is unreliable when called from an
        // accessory app whose panel is currently key — it frequently no-ops,
        // which is why "Open IDE" only worked sometimes. The deprecated form
        // still works on every version, so we use it and also do a second
        // pass on the next runloop tick to win any activation race.
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !app.isActive { app.activate(options: [.activateIgnoringOtherApps]) }
        }
    }
}
