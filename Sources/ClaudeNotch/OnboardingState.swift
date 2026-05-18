import AppKit
import Combine
import IOKit.hid
import ServiceManagement

/// Backing state for the onboarding window. Polls permission status while
/// the window is open so the UI updates immediately after the user grants
/// access in System Settings (no need to relaunch).
@MainActor
final class OnboardingState: ObservableObject {
    @Published var accessibility: Bool = false
    @Published var inputMonitoring: Bool = false
    @Published var hooksInstalled: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var hasJq: Bool = false
    @Published var hookInstallError: String? = nil
    @Published var isInstallingHooks: Bool = false

    private var timer: Timer?

    /// All steps users *must* complete for the app to function. Login item
    /// is intentionally not required.
    var allRequiredDone: Bool {
        accessibility && inputMonitoring && hooksInstalled
    }

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibility   = TerminalAutomator.isAccessibilityTrusted
        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        hooksInstalled  = HookInstaller.isInstalled
        hasJq           = HookInstaller.hasJq
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Actions

    func requestAccessibility() {
        TerminalAutomator.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func installHooks() {
        isInstallingHooks = true
        hookInstallError = nil
        // Run on a bg queue — JSON merge + file IO is fast but blocking, no
        // point hitching the UI even briefly.
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
