import AppKit
import ApplicationServices
import Combine
import IOKit.hid
import ServiceManagement

/// Backing state for the onboarding window. Polls permission status while
/// the window is open so the UI updates immediately after the user grants
/// access in System Settings (no need to relaunch).
///
/// macOS quirk: AXIsProcessTrusted / IOHIDCheckAccess often keep returning
/// `false` for an *already-running* process for a few seconds after the
/// user flips the switch — sometimes until the app is quit and relaunched.
/// We mitigate by:
///   - polling fast (500ms)
///   - re-checking on app-activation (user tabbing back from Settings)
///   - using AXIsProcessTrustedWithOptions(prompt: false) which forces a
///     fresh TCC lookup instead of the cached one
///   - surfacing a "Quit & relaunch" hint once a grant has clearly stuck
///     in Settings but the running process still sees `false`
@MainActor
final class OnboardingState: ObservableObject {
    @Published var accessibility: Bool = false
    @Published var inputMonitoring: Bool = false
    @Published var hooksInstalled: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var hasJq: Bool = false
    @Published var hookInstallError: String? = nil
    @Published var isInstallingHooks: Bool = false

    /// Set when the user clicks "Open Settings" for a given permission.
    /// Drives the "stuck? quit & relaunch" hint after a grace period.
    @Published var accessibilityGrantClickedAt: Date? = nil
    @Published var inputMonitoringGrantClickedAt: Date? = nil

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Hint thresholds (seconds since the user clicked "Open Settings"
    /// without the status flipping to true). After this we show the
    /// "Quit & relaunch" guidance.
    private let stuckHintAfter: TimeInterval = 6

    var allRequiredDone: Bool {
        accessibility && inputMonitoring && hooksInstalled
    }

    var accessibilityNeedsRelaunch: Bool {
        guard let t = accessibilityGrantClickedAt, !accessibility else { return false }
        return Date().timeIntervalSince(t) > stuckHintAfter
    }

    var inputMonitoringNeedsRelaunch: Bool {
        guard let t = inputMonitoringGrantClickedAt, !inputMonitoring else { return false }
        return Date().timeIntervalSince(t) > stuckHintAfter
    }

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Re-check immediately when the user tabs back from System Settings.
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
            activationObserver = nil
        }
    }

    func refresh() {
        // Force a non-cached TCC lookup. AXIsProcessTrusted() can return
        // stale `false` for the lifetime of the process; the WithOptions
        // form (with prompt: false) re-queries the database.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let ax = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        accessibility   = ax
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        hooksInstalled  = HookInstaller.isInstalled
        hasJq           = HookInstaller.hasJq
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        // If the status flipped to true after the user clicked grant,
        // clear the "clicked at" timestamp so the relaunch hint disappears.
        if accessibility   { accessibilityGrantClickedAt = nil }
        if inputMonitoring { inputMonitoringGrantClickedAt = nil }
    }

    // MARK: - Actions

    func requestAccessibility() {
        TerminalAutomator.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        accessibilityGrantClickedAt = Date()
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        inputMonitoringGrantClickedAt = Date()
    }

    /// Quit and relaunch ourselves — needed when TCC has clearly granted
    /// the permission (toggle is on in Settings) but our running process
    /// is still seeing `false`. macOS occasionally only picks up the
    /// new grant on a fresh launch.
    func relaunch() {
        guard let bundlePath = Bundle.main.bundlePath as String?,
              !bundlePath.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        // -n forces a new instance; we'll terminate the current one below.
        task.arguments = ["-n", bundlePath]
        try? task.run()
        // Give launchd a beat to start the new instance before we die.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    func installHooks() {
        isInstallingHooks = true
        hookInstallError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try HookInstaller.install()
                Task { @MainActor in
                    self.isInstallingHooks = false
                    self.refresh()
                }
            } catch {
                Task { @MainActor in
                    self.isInstallingHooks = false
                    self.hookInstallError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("ClaudeNotch: login toggle failed - \(error)")
        }
        refresh()
    }

    func copyBrewInstallCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("brew install jq", forType: .string)
    }
}
