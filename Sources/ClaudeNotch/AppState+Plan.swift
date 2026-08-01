import Foundation

/// The plan behind the numbers: which subscription this Mac is signed into, how
/// close its limits are, and whether paid usage credits are carrying the session.
///
/// PlanReader does the parsing; this decides when to re-read it and how to say it
/// in the few characters a menu bar allows.
extension AppState {

    /// Re-read Claude Code's cache. Off the main actor: the file is well over
    /// 100 KB of unrelated state, and this runs on a timer.
    func refreshPlan() {
        Task.detached(priority: .utility) {
            let snapshot = PlanReader.load()
            await MainActor.run { [weak self] in self?.applyPlan(snapshot) }
        }
    }

    func applyPlan(_ snapshot: PlanReader.Snapshot?) {
        let previous = plan
        plan = snapshot
        noteCreditsEngaged(from: previous, to: snapshot)
    }

    /// Claude Code refreshes the cache when it talks to the API, so re-reading
    /// faster than this only re-reads the same numbers. Slow enough to be free,
    /// often enough that the menu bar is not stale by a session.
    func ensurePlanTimer() {
        guard planTimer == nil else { return }
        refreshPlan()
        planTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPlan() }
        }
    }

    func setShowPlanInMenuBar(_ on: Bool) {
        showPlanInMenuBar = on
        if on { ensurePlanTimer() }
        schedulePersist()
    }

    /// "Pro · WK 13%", or nil when there is nothing worth the width.
    var menuBarPlanLabel: String? { Self.planLabel(plan) }

    nonisolated static func planLabel(_ snapshot: PlanReader.Snapshot?) -> String? {
        guard let snapshot else { return nil }
        let tier = snapshot.account?.tier
        guard let limit = tightestLimit(snapshot.limits) else { return tier }
        let pct = "\(shortLimitLabel(limit.kind)) \(Int(limit.percent.rounded()))%"
        return tier.map { "\($0) · \(pct)" } ?? pct
    }

    /// The limit closest to stopping you, which is the only one worth a menu bar.
    /// Ties go to the first, so a 0% account reads as its 5-hour window rather
    /// than whichever window sorted first.
    nonisolated static func tightestLimit(_ limits: [PlanReader.Limit]) -> PlanReader.Limit? {
        limits.max { $0.percent < $1.percent }
    }

    /// Two or three characters. The full name does not fit beside a bell.
    nonisolated static func shortLimitLabel(_ kind: String) -> String {
        switch kind {
        case "session", "five_hour":    return "5H"
        case "weekly_all", "seven_day": return "WK"
        case "weekly_opus":             return "OPUS"
        case "weekly_sonnet":           return "SON"
        default:
            let letters = kind.split(separator: "_").compactMap(\.first)
            return String(letters).uppercased()
        }
    }

    /// The status-bar slots worth drawing. A credits slot with credits switched
    /// off would read $0.00 for ever, so it is dropped rather than shown empty.
    nonisolated static func visibleStatusItems(_ items: [StatusBarItem], creditsOn: Bool) -> [StatusBarItem] {
        items.filter { $0 != .credits || creditsOn }
    }

    // MARK: - Credits engaging

    /// Credits are the moment money starts, and nothing announces it: a session
    /// simply keeps going where it would have stopped. This fires one card the
    /// first time spend appears, and again only if it goes back to zero and
    /// returns (a new billing period).
    func noteCreditsEngaged(from previous: PlanReader.Snapshot?, to current: PlanReader.Snapshot?) {
        guard let current, Self.creditsJustEngaged(from: previous?.credits, to: current.credits) else { return }
        guard let credits = current.credits else { return }
        let spent = credits.spent ?? credits.usedCredits ?? 0
        let amount = spent.formatted(.currency(code: credits.currency ?? "USD"))
        let detail: String
        if let limit = credits.spendLimit ?? credits.monthlyLimit {
            detail = "\(amount) of \(limit.formatted(.currency(code: credits.currency ?? "USD"))) used"
        } else {
            detail = "\(amount) used so far"
        }
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: "Paid usage credits are covering this session",
            detail: detail,
            toolName: "UsageCredits", source: "ClaudeNotch", cwd: currentCwd,
            originatorBundleID: nil, resolver: { _, _ in }))
    }

    /// Pure so the transition can be tested without a billing period going by.
    ///
    /// Only a rise from nothing counts. Every later refresh reports a larger
    /// number, and a card per refresh would make the one that matters invisible.
    nonisolated static func creditsJustEngaged(from before: PlanReader.Credits?,
                                               to after: PlanReader.Credits?) -> Bool {
        guard let after, after.isEnabled else { return false }
        let now = after.spent ?? after.usedCredits ?? 0
        guard now > 0 else { return false }
        // No previous reading means the app just launched into a period that is
        // already running. Announcing then would be news about nothing.
        guard let before else { return false }
        let then = before.spent ?? before.usedCredits ?? 0
        return then <= 0
    }
}
