import AppKit
import UserNotifications

/// Mirrors blocking permission cards to native macOS notifications so the user
/// can Allow / Deny from the lock screen, another Space, or Notification Center
/// without bringing the notch forward.
///
/// Why this also "respects Focus": native notifications are gated by the OS.
/// During a Focus / Do Not Disturb session macOS suppresses the banner and
/// sound and quietly files the alert in Notification Center + the lock screen,
/// so the mirror inherently honors Focus with no state-file snooping (which
/// macOS blocks behind Full Disk Access anyway).
///
/// The notch itself is unchanged — this is an *additional*, remote-actionable
/// surface. The mirrored notification carries no sound; the notch already
/// plays the alert when you're at the desk, and a double chime reads as noise.
@MainActor
final class NotificationBridge: NSObject, PermissionMirroring {
    weak var state: AppState?

    // Category + action identifiers. Kept short and stable — they're matched by
    // string in didReceive.
    private static let catSafe = "CN_PERMISSION"
    private static let catDanger = "CN_PERMISSION_DANGER"
    private static let actAllow = "CN_ALLOW"
    private static let actDeny = "CN_DENY"
    private static let actDenyReason = "CN_DENY_REASON"

    private var authorized = false

    /// Register categories and ask for permission. Safe to call once at launch.
    /// Guards against running outside a real .app bundle, where
    /// UNUserNotificationCenter.current() traps.
    func start() {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let allow = UNNotificationAction(identifier: Self.actAllow, title: "Allow",
                                         options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.actDeny, title: "Deny",
                                        options: [.destructive])
        let denyReason = UNTextInputNotificationAction(
            identifier: Self.actDenyReason, title: "Deny with reason…",
            options: [], textInputButtonTitle: "Deny",
            textInputPlaceholder: "What should Claude do instead?")

        // Safe commands: Allow / Deny / Deny-with-reason inline.
        let safe = UNNotificationCategory(identifier: Self.catSafe,
                                          actions: [allow, deny, denyReason],
                                          intentIdentifiers: [], options: [])
        // Dangerous commands never get a remote Allow — confirming a destructive
        // command should require coming to the Mac (Touch ID / hold-to-confirm).
        // Tapping the body brings the app forward to do that.
        let danger = UNNotificationCategory(identifier: Self.catDanger,
                                            actions: [deny, denyReason],
                                            intentIdentifiers: [], options: [])

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([safe, danger])
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    // MARK: - PermissionMirroring

    func mirror(_ req: PermissionRequest) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        let dangerous = req.isDangerous
        let block = req.budgetBlock
        if block != nil {
            content.title = "💸 Over budget: \(req.toolName)"
        } else {
            content.title = dangerous ? "⚠️ \(req.toolName) needs your OK"
                                      : "Allow \(req.toolName)?"
        }
        let project = (req.cwd as NSString).lastPathComponent
        if !project.isEmpty { content.subtitle = project }
        var body = req.detail
        if let b = block {
            body = "Over \(b.scope) budget, \(b.pct)% of cap\n\(req.detail)"
        }
        if dangerous, !req.dangerReasons.isEmpty {
            // Show just the flagged tokens (the bit before the explanation),
            // not the full "token — explanation" microcopy, which is long and
            // truncates mid-word in a banner.
            let tokens = req.dangerReasons.map { reason -> String in
                for sep in [" — ", " - "] {
                    if let r = reason.range(of: sep) { return String(reason[..<r.lowerBound]) }
                }
                return reason
            }
            body += "\nFlagged: " + tokens.joined(separator: ", ")
        }
        content.body = body
        content.categoryIdentifier = dangerous ? Self.catDanger : Self.catSafe
        content.threadIdentifier = project.isEmpty ? "claudenotch" : project
        // No sound: the notch handles audio at the desk. interruptionLevel
        // stays .active so a Focus session suppresses the banner (the point).

        let request = UNNotificationRequest(identifier: req.id.uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func withdraw(_ id: UUID) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    func withdrawAll() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func sendCompletion(project: String, snippet: String) {
        guard Bundle.main.bundleIdentifier != nil, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = project.isEmpty ? "Claude finished" : project
        content.subtitle = project.isEmpty ? "" : "Claude finished"
        if !snippet.isEmpty { content.body = String(snippet.prefix(200)) }
        content.sound = .default
        content.threadIdentifier = "claudenotch-done"
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func sendDigest(_ summary: DailySpendSummary) {
        guard Bundle.main.bundleIdentifier != nil, authorized else { return }
        let content = UNMutableNotificationContent()
        let cost = String(format: "$%.2f", summary.costUSD)
        let sessions = summary.sessionCount == 1 ? "1 session" : "\(summary.sessionCount) sessions"
        content.title = "Yesterday: \(cost) · \(sessions)"
        if !summary.topProject.isEmpty { content.subtitle = "Top project: \(summary.topProject)" }
        if summary.totalTokens > 0 {
            let k = summary.totalTokens >= 1000 ? "\(summary.totalTokens / 1000)k tokens" : "\(summary.totalTokens) tokens"
            content.body = k
        }
        content.threadIdentifier = "claudenotch-digest"
        let req = UNNotificationRequest(identifier: "digest-\(AppState.dayKey(Date()))",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

extension NotificationBridge: UNUserNotificationCenterDelegate {
    // Show the banner even though we're a (window-less) foreground accessory app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // The user acted on the notification (possibly from the lock screen). Map it
    // back to the queued request and resolve it; the resolver unblocks Claude.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let reason = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor [weak self] in
            self?.handle(id: id, action: action, reason: reason)
            completionHandler()
        }
    }

    @MainActor
    private func handle(id: String, action: String, reason: String?) {
        guard let state, let uuid = UUID(uuidString: id),
              let req = state.permissionQueue.first(where: { $0.id == uuid }) else { return }
        switch action {
        case Self.actAllow:
            // Dangerous commands can't be allowed remotely — defend in depth in
            // case a stale notification still shows the action.
            if req.isDangerous {
                NSApp.activate(ignoringOtherApps: true)
            } else {
                state.resolvePermission(req, decision: .allow)
            }
        case Self.actDeny:
            state.resolvePermission(req, decision: .deny)
        case Self.actDenyReason:
            state.resolvePermission(req, decision: .deny,
                                    reason: (reason?.isEmpty == false) ? reason : nil)
        default:
            // Default action = tapped the body. Bring the app forward so they
            // can use the notch card (and Touch ID for dangerous commands).
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
