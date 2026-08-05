import SwiftUI
import AppKit

// The always-visible bottom status bar row.



// MARK: - Status bar row

/// Always-visible compact bar shown in the collapsed notch and appended at the
/// bottom of the persistent-notch idle view. Shows the rolling 5-hour cost and
/// weekly cost as labelled mini progress bars relative to their configured caps.
struct StatusBarRow: View {
    @ObservedObject var state: AppState

    /// Display data for one bar slot: bar fill (0...1, nil = no data) and the
    /// right-side label. For `.sessionCost` we skip the fill bar and show raw $.
    private struct BarData {
        var pct: CGFloat?       // nil hides the bar track (cost item); 0...1 fills it
        var text: String        // "38%", "$0.42", or "—"
        var showBar: Bool       // false for session-cost item
        /// "1h 12m" until this limit's window resets. Empty when unknown.
        var resetIn: String = ""
        /// How old this reading is, once it is old enough to matter. Nil = fresh.
        var age: String? = nil
        var tooltip: String = ""
    }

    private func barData(for item: StatusBarItem, showCountdown: Bool) -> BarData {
        switch item {
        case .fiveHourLimit:
            let p = Self.livePercent(state.fiveHourLimitPercent, resetAt: state.fiveHourResetAt)
            return BarData(pct: p, text: p.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", showBar: true,
                           resetIn: showCountdown ? Self.countdown(state.fiveHourResetAt) : "",
                           age: Self.readingAge(state.limitsUpdatedAt),
                           tooltip: limitTooltip(L("5-hour limit", comment: "Name of the rolling five-hour usage window"),
                                                 pct: p, resetAt: state.fiveHourResetAt,
                                                 forecast: state.fiveHourForecast))
        case .weeklyLimit:
            let p = Self.livePercent(state.weeklyLimitPercent, resetAt: state.weeklyResetAt)
            return BarData(pct: p, text: p.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", showBar: true,
                           resetIn: showCountdown ? Self.countdown(state.weeklyResetAt) : "",
                           age: Self.readingAge(state.limitsUpdatedAt),
                           tooltip: limitTooltip(L("Weekly limit", comment: "Name of the weekly usage window"),
                                                 pct: p, resetAt: state.weeklyResetAt,
                                                 forecast: state.weeklyForecast))
        case .sessionCost:
            return BarData(pct: nil, text: ClaudeUsageReader.fmtMoney(state.currentCostUSD), showBar: false,
                           tooltip: L("Estimated cost of this session", comment: "Tooltip on the session-cost readout"))
        case .credits:
            // Real money, unlike the estimate beside it, so it says the amount
            // rather than a percentage unless there is a budget to be a percentage of.
            let c = state.plan?.credits
            let spent = c?.spent ?? c?.usedCredits ?? 0
            let pct = (c?.utilization).map { CGFloat($0 / 100) }
            return BarData(pct: pct,
                           text: ClaudeUsageReader.fmtMoney(spent),
                           showBar: pct != nil,
                           tooltip: creditTooltip(c))
        }
    }

    /// Credits are billed on top of the subscription, so the tooltip says what
    /// the number is rather than leaving "CR $2.40" to be guessed at.
    private func creditTooltip(_ c: PlanReader.Credits?) -> String {
        guard let c else { return L("Usage credits", comment: "Tooltip when the credit amount is unknown") }
        let spent = c.spent ?? c.usedCredits ?? 0
        let amount = ClaudeUsageReader.fmtMoney(spent)
        if let limit = c.spendLimit ?? c.monthlyLimit {
            return String(format: L("Paid usage credits: %1$@ of %2$@ this period",
                                    comment: "Credit tooltip with a cap. %1$@ is spent, %2$@ is the cap"),
                          amount, ClaudeUsageReader.fmtMoney(limit))
        }
        return String(format: L("Paid usage credits: %@ this period",
                                comment: "Credit tooltip with no cap. %@ is the amount spent"), amount)
    }

    /// A usage percentage is only worth showing while the window it was measured
    /// in is still running. Past its reset instant it describes a window that no
    /// longer exists, so it becomes "—" until the next status line replaces it.
    /// This is what stops a stale reading sitting there looking like a fact.
    static func livePercent(_ percent: Double, resetAt: Date?) -> CGFloat? {
        guard percent >= 0 else { return nil }
        if let resetAt, resetAt <= Date() { return nil }
        return CGFloat(percent)
    }

    /// The countdown, or nothing once the window it describes has already reset.
    ///
    /// Claude Code only pushes a status line when it redraws, so a reading can
    /// sit in the notch long after it stopped being true. Once its reset instant
    /// is in the past, the percentage beside it is describing a window that no
    /// longer exists, and "0% · now" is a confident-looking lie. Say nothing
    /// instead, until the next status line brings a real number.
    private static func countdown(_ resetAt: Date?) -> String {
        guard let resetAt, resetAt > Date() else { return "" }
        return ClaudeUsageReader.resetCountdown(until: resetAt)
    }

    private static let resetClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func limitTooltip(_ name: String, pct: CGFloat?, resetAt: Date?,
                              forecast: BurnRate.Forecast? = nil) -> String {
        var parts: [String] = [name]
        if let pct {
            parts.append(String(format: L("%d%% used", comment: "Limit tooltip fragment. %d is a percentage"),
                                Int((pct * 100).rounded())))
        }
        // Only when the cap would arrive before the window resets, and soon
        // enough to change what you do next.
        if let f = forecast, !f.resetsFirst,
           f.secondsRemaining <= BurnRate.worthWarningWithin {
            parts.append(String(format: L("about %@ left at this rate",
                                          comment: "Limit tooltip fragment. %@ is a duration such as 40 min"),
                                BurnRate.humanDuration(f.secondsRemaining)))
        }
        if let resetAt {
            parts.append(String(format: L("resets in %1$@ (%2$@)",
                                          comment: "Limit tooltip fragment. %1$@ is a countdown, %2$@ is a clock time"),
                                ClaudeUsageReader.resetCountdown(until: resetAt),
                                Self.resetClockFormatter.string(from: resetAt)))
        }
        if let age = Self.readingAge(state.limitsUpdatedAt) {
            parts.append(String(format: L("last reported %@ ago",
                                          comment: "Limit tooltip fragment. %@ is how long ago the reading arrived"), age))
        }
        parts.append(L("Claude Code only reports usage while a session is running",
                       comment: "Limit tooltip fragment explaining why a reading can be stale"))
        return parts.joined(separator: " · ")
    }

    /// How old the newest limit reading is, or nil while it is fresh enough to
    /// pass for current.
    ///
    /// Claude Code reports usage only while a session is redrawing its status
    /// line. Leave Claude idle and the newest reading we have ages quietly, which
    /// is how the notch could sit there showing 31% while `/usage` said 52%. An
    /// old number presented as a current one is worse than no number.
    static let staleAfter: TimeInterval = 5 * 60

    static func readingAge(_ updatedAt: Date?) -> String? {
        guard let updatedAt else { return nil }
        let age = Date().timeIntervalSince(updatedAt)
        guard age >= staleAfter else { return nil }
        return ClaudeUsageReader.ageDescription(seconds: age)
    }

    private func tint(for pct: CGFloat) -> Color {
        switch pct {
        case ..<0.6:  return Color(red: 0.39, green: 0.70, blue: 0.93)
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    private struct BarWidget: View {
        let label: String
        let data: BarData
        let tint: Color

        var body: some View {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
                if data.showBar {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10)).frame(width: 52, height: 3)
                        Capsule().fill(tint.opacity(0.9)).frame(width: 52 * (data.pct ?? 0), height: 3)
                    }
                }
                Text(data.text)
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white.opacity(0.65))
                // "82%" tells you that you are in trouble. It does not tell you
                // whether you can wait it out, which is the thing you actually
                // want to know, and Claude Code reports it.
                if !data.resetIn.isEmpty {
                    Text(data.resetIn)
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.32))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                // An old reading must not pass for a current one.
                if let age = data.age {
                    Text(String(format: L("· %@ old", comment: "Staleness marker beside a usage reading. %@ is an age such as 12 min"), age))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.28))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .help(data.tooltip)
            // The bar is the reading; the text beside it is an abbreviation of
            // the same thing. Spoken, only the tooltip says what either means.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(data.tooltip.isEmpty ? label : data.tooltip)
            .accessibilityValue(data.text)
        }
    }

    var body: some View {
        let items = AppState.visibleStatusItems(state.statusBarItems,
                                                creditsOn: state.plan?.credits?.isEnabled ?? false)
        // Re-render every half minute so the countdowns actually count down.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    let d = barData(for: item, showCountdown: true)
                    BarWidget(label: item.barLabel, data: d, tint: tint(for: d.pct ?? 0))
                    if idx < items.count - 1 { separator }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 11)
            .padding(.horizontal, 14)
    }
}
