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

    // Bridge to the live app state for the auto-approve toggle.
    weak var appState: AppState?
    var autoApprove: Bool { appState?.autoApprove ?? false }
    func toggleAutoApprove() {
        appState?.setAutoApprove(!(appState?.autoApprove ?? false))
        objectWillChange.send()
    }

    /// What the notch calls itself. Empty means the default (the agent name).
    /// Backs the onboarding "name your notch" field; mirrors Settings > Notch.
    var notchName: String {
        get { appState?.customNotchTitle ?? "" }
        set { appState?.setCustomNotchTitle(newValue); objectWillChange.send() }
    }

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

    /// Everything this window shows about the machine, gathered off the main
    /// thread.
    ///
    /// This runs twice a second while the Setup window is open, and every one
    /// of these asks the system a question: two TCC lookups, a launchd XPC
    /// round trip, and, on a Mac with no jq on the usual paths, a subprocess.
    /// On the main thread that is the window's own draw loop competing with
    /// four system services twice a second, and on a machine where none of
    /// them are warm — a fresh Mac, first launch, nothing granted yet — it is
    /// enough for macOS to call the app unresponsive.
    ///
    /// None of these values are needed synchronously. They are booleans on a
    /// checklist, so they are read on a background queue and published when
    /// they arrive.
    private struct Probe {
        var accessibility = false
        var inputMonitoring = false
        var hooksInstalled = false
        var hasJq = false
        var launchAtLogin = false
    }

    /// jq is either installed or it is not; it does not change twice a second,
    /// and finding out costs a subprocess when it is not on a known path.
    private nonisolated(unsafe) static var jqCache: (value: Bool, at: Date)?
    private static let jqCacheLock = NSLock()
    private static let jqCacheTTL: TimeInterval = 10

    nonisolated private static func cachedHasJq() -> Bool {
        jqCacheLock.lock()
        let hit = jqCache
        jqCacheLock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < jqCacheTTL { return hit.value }
        let value = HookInstaller.hasJq
        jqCacheLock.lock()
        jqCache = (value, Date())
        jqCacheLock.unlock()
        return value
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            var probe = Probe()
            // Force a non-cached TCC lookup. AXIsProcessTrusted() can return
            // stale `false` for the lifetime of the process; the WithOptions
            // form (with prompt: false) re-queries the database.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
            probe.accessibility = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            probe.inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            probe.hooksInstalled = HookInstaller.isInstalled
            probe.hasJq = Self.cachedHasJq()
            if #available(macOS 13.0, *) {
                probe.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
            await MainActor.run { [probe] in self.apply(probe) }
        }
    }

    /// Publish a probe. Assignments are guarded so an unchanged value does not
    /// wake SwiftUI twice a second for nothing.
    private func apply(_ probe: Probe) {
        if accessibility   != probe.accessibility   { accessibility = probe.accessibility }
        if inputMonitoring != probe.inputMonitoring { inputMonitoring = probe.inputMonitoring }
        if hooksInstalled  != probe.hooksInstalled  { hooksInstalled = probe.hooksInstalled }
        if hasJq           != probe.hasJq           { hasJq = probe.hasJq }
        if launchAtLogin   != probe.launchAtLogin   { launchAtLogin = probe.launchAtLogin }
        // If the status flipped to true after the user clicked grant,
        // clear the "clicked at" timestamp so the relaunch hint disappears.
        if accessibility   { accessibilityGrantClickedAt = nil }
        if inputMonitoring { inputMonitoringGrantClickedAt = nil }
    }

    /// The user did something that could change jq or the hooks, so the next
    /// probe must not answer from the cache.
    nonisolated static func invalidateProbeCache() {
        jqCacheLock.lock()
        jqCache = nil
        jqCacheLock.unlock()
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try HookInstaller.install()
                // The install may have been what put jq on the path, or what
                // wired the hooks, so the next probe asks the machine rather
                // than repeating what it knew ten seconds ago.
                OnboardingState.invalidateProbeCache()
                Task { @MainActor in
                    self?.isInstallingHooks = false
                    self?.refresh()
                }
            } catch {
                Task { @MainActor in
                    self?.isInstallingHooks = false
                    self?.hookInstallError = (error as? LocalizedError)?.errorDescription
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
