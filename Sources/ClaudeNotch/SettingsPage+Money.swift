import SwiftUI
import AppKit

// The two pages about money: Plan (what this Mac is signed into and what it is
// allowed) and Budget (what it costs and where the caps are). Split out of
// SettingsWindow.swift, one concern per file, the way AppState is split.

extension SettingsView {
    /// What plan you are on and what it has left, read out of Claude Code's own
    /// cache. The Budget page answers "what am I spending"; this one answers
    /// "what am I allowed", which until now was only visible as two unlabelled
    /// percentages with no plan attached to them.
    var plan: some View {
        page(L("Plan", comment: "Settings page title")) {
            if let p = state.plan {
                if let a = p.account {
                    sectionLabel(L("Your plan", comment: "Settings section heading"))
                    group {
                        statRow("Plan", a.tier)
                        // Which login this is. People sign out of one account and
                        // into another, and the limits below belong to whichever
                        // one is current, so the page has to say which.
                        if let email = a.email { divider; statRow("Account", email) }
                        if let name = a.displayName { divider; statRow("Name", name) }
                        if let org = a.organization { divider; statRow("Organization", org) }
                        if let billing = a.billing { divider; statRow("Billing", billing) }
                        if let seat = a.seat { divider; statRow("Seat", seat.capitalized) }
                        if let role = a.role { divider; statRow("Role", role.capitalized) }
                        if let since = a.memberSince {
                            divider
                            statRow("Subscribed", since.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let trial = a.trialEndsAt {
                            divider
                            statRow("Trial ends", trial.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }

                if !p.limits.isEmpty {
                    sectionLabel(L("Limits", comment: "Settings section heading"))
                    group {
                        ForEach(Array(p.limits.enumerated()), id: \.element.kind) { idx, limit in
                            limitRow(limit.label,
                                     pct: limit.percent / 100,
                                     resetAt: limit.resetsAt,
                                     window: limit.kind.hasPrefix("weekly") || limit.kind == "seven_day"
                                             ? 7 * 24 * 3600 : 5 * 3600)
                            if idx < p.limits.count - 1 { divider }
                        }
                    }
                }

                if let c = p.credits {
                    sectionLabel(L("Usage credits", comment: "Settings section heading"))
                    Text(L("Credits carry a session past the plan limits instead of stopping it, and are billed on top of the subscription.", comment: "Settings explanation"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    group {
                        statRow("Status", c.isEnabled
                                ? L("On", comment: "Usage credits are switched on")
                                : L("Off", comment: "Usage credits are switched off"))
                        if let reason = c.disabledReason, !c.isEnabled {
                            divider
                            statRow("Reason", PlanReader.disabledReasonText(reason))
                        }
                        if let used = c.usedCredits {
                            divider
                            statRow("Used this month", money(used, c.currency))
                        }
                        if let limit = c.monthlyLimit {
                            divider
                            statRow("Monthly limit", money(limit, c.currency))
                        }
                        if let spent = c.spent, spent > 0 || c.isEnabled {
                            divider
                            statRow("Spent", money(spent, c.currency))
                        }
                        if let cap = c.spendLimit {
                            divider
                            statRow("Spend limit", money(cap, c.currency))
                        }
                        if let balance = c.balance {
                            divider
                            statRow("Balance", money(balance, c.currency))
                        }
                        if let reload = c.autoReload {
                            divider
                            statRow("Auto-reload", reload
                                    ? L("On", comment: "Usage credits are switched on")
                                    : L("Off", comment: "Usage credits are switched off"))
                        }
                        if c.spendLimitReached {
                            divider
                            statRow("Spend limit", L("Reached", comment: "The usage-credit spend limit is used up"))
                        }
                    }
                    if let u = c.utilization, c.isEnabled {
                        group { limitRow("Credit budget", pct: u / 100, resetAt: nil, window: 30 * 24 * 3600) }
                    }
                }

                HStack(spacing: 10) {
                    // Read-only by design: turning credits on, capping the spend
                    // or buying more is a billing change, so it happens on
                    // Anthropic's site under the account's own login.
                    Link(L("Manage on claude.ai", comment: "Button opening the Anthropic usage settings page"),
                         destination: URL(string: ProjectLinks.planSettings)!)
                    Link(L("How credits work", comment: "Button opening Anthropic's help page about usage credits"),
                         destination: URL(string: ProjectLinks.creditsHelp)!)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                HStack(spacing: 10) {
                    if let at = p.fetchedAt {
                        Text(String(format: L("Claude Code last checked this %@.", comment: "Settings explanation, freshness of the plan numbers"),
                                    at.formatted(.relative(presentation: .named))))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Refresh", comment: "Button that re-reads the plan details")) {
                        state.refreshPlan()
                    }
                    .controlSize(.small)
                }
            } else if state.isApiKeyBilling || state.apiKeyEnvKey != nil {
                apiKeyBillingSection
            } else {
                Text(L("No plan details yet. Claude Code writes them to its own config when it next talks to the API, so run a session and come back.", comment: "Settings explanation shown when the plan cache is missing"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L("Read from the config Claude Code keeps on this Mac. Nothing is requested from Anthropic, and your account details never leave the machine.", comment: "Settings explanation"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: section) {
            // The timer refreshes this in the background; opening the page is a
            // moment where a stale reading would be noticed, so re-read then too.
            guard section == .plan else { return }
            state.refreshPlan()
        }
    }

    /// Shown instead of a blank page when Claude Code is authenticated with a
    /// raw API key: there is no subscription plan or rate-limit percentage to
    /// read, ever, so saying that plainly beats a "come back later" that will
    /// never resolve.
    @ViewBuilder
    private var apiKeyBillingSection: some View {
        sectionLabel(L("Your plan", comment: "Settings section heading"))
        group {
            statRow("Billing", L("API key (pay-as-you-go)", comment: "Settings row value: authenticated via ANTHROPIC_API_KEY"))
            if let key = state.apiKeyEnvKey {
                divider
                statRow("Key", APIKeyValidator.masked(key))
            }
            if let result = state.apiKeyCheckResult {
                divider
                switch result {
                case .valid:
                    statRow("Status", L("Working", comment: "The API key was accepted by Anthropic"))
                case .invalid(let reason):
                    statRow("Status", reason)
                case .networkError(let reason):
                    statRow("Status", reason)
                }
            }
        }
        Text(L("Claude Code is authenticated with ANTHROPIC_API_KEY instead of a subscription login, so there is no plan or rate-limit percentage to show here. Usage is billed per token instead; cost tracking on the Budget page works the same either way.", comment: "Settings explanation for API-key billing"))
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if state.apiKeyEnvKey != nil {
            HStack(spacing: 8) {
                if state.apiKeyCheckInFlight { ProgressView().controlSize(.small) }
                Button(L("Check key", comment: "Button that asks Anthropic whether the API key is accepted")) {
                    state.checkApiKey()
                }
                .controlSize(.small)
                .disabled(state.apiKeyCheckInFlight)
            }
        }
    }

    var budget: some View {
        page(L("Budget", comment: "Settings page title")) {
            if state.fiveHourLimitPercent >= 0 || state.weeklyLimitPercent >= 0 {
                sectionLabel(L("Plan usage limits", comment: "Settings section heading"))
                Text(L("Your Claude plan's rate limits, as Claude Code last reported them. These are usage limits, not dollar caps.", comment: "Settings explanation"))
                    .font(.callout).foregroundStyle(.secondary)
                group {
                    if state.fiveHourLimitPercent >= 0 {
                        limitRow("5-hour limit", pct: state.fiveHourLimitPercent,
                                 resetAt: state.fiveHourResetAt, window: 5 * 3600)
                    }
                    if state.fiveHourLimitPercent >= 0, state.weeklyLimitPercent >= 0 { divider }
                    if state.weeklyLimitPercent >= 0 {
                        limitRow("Weekly limit", pct: state.weeklyLimitPercent,
                                 resetAt: state.weeklyResetAt, window: 7 * 24 * 3600)
                    }
                }
                if let updated = state.limitsUpdatedAt {
                    Text(String(format: L("Updated %@.", comment: "Money page. %@ is a relative time such as \"2 minutes ago\""), updated.formatted(.relative(presentation: .named))))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            forecastSection

            Text(L("Warn when estimated cost crosses a cap. Set a cap to 0 to disable it.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            sectionLabel(L("Caps (USD)", comment: "Settings section heading"))
            group {
                capRow("Per session", get: { state.sessionCostCap }, set: { state.setSessionCostCap($0) })
                divider
                capRow("Per day", get: { state.dailyCostCap }, set: { state.setDailyCostCap($0) })
                divider
                capRow("Per 5-hour window", get: { state.fiveHourCostCap }, set: { state.setFiveHourCostCap($0) })
                divider
                capRow("Per week", get: { state.weeklyCostCap }, set: { state.setWeeklyCostCap($0) })
            }
            group {
                row(L("Hard-stop at the cap", comment: "Settings toggle"),
                    L("Block new tool runs once a cap is crossed, instead of only warning.", comment: "Settings toggle explanation"),
                    Binding(get: { state.enforceBudget }, set: { state.setEnforceBudget($0) }))
            }
        }
        // The projections read the per-day cost map, which is filled by a
        // transcript scan. Without this the page would show yesterday's numbers
        // (or none at all) until something else happened to refresh it.
        .task(id: section) {
            guard section == SettingsSection.budget else { return }
            state.refreshProjectSpend()
            let today = await Task.detached(priority: .utility) {
                ClaudeUsageReader.compute().today.costUSD
            }.value
            state.noteTodayCost(today)
        }
    }

    /// Where the spend is heading, rather than where it has been.
    ///
    /// The caps below warn at 80% and 100%, which is late: by the time the
    /// second one fires the money is gone. This says what today finishes at and
    /// what the month comes to, while there is still a decision to make.
    @ViewBuilder
    private var forecastSection: some View {
        let monthly = CostForecast.month(dailyCostUSD: state.weekCostByDay)
        let daily = CostForecast.today(spent: state.todayCostUSD, cap: state.dailyCostCap)
        if monthly != nil || daily != nil {
            sectionLabel(L("Where this is heading", comment: "Settings section heading"))
            group {
                if let d = daily {
                    statRow(L("Today, at this rate", comment: "Settings row: projected spend for the whole day"),
                            ClaudeUsageReader.fmtMoney(d.projectedTotal))
                    if let crossesAt = d.crossesAt {
                        divider
                        statRow(L("Passes the daily cap", comment: "Settings row: when today's spend crosses the cap"),
                                crossesAt.formatted(date: .omitted, time: .shortened))
                    }
                }
                if let m = monthly {
                    if daily != nil { divider }
                    statRow(L("This month so far", comment: "Settings row: spend since the first of the month"),
                            ClaudeUsageReader.fmtMoney(m.spentSoFar))
                    divider
                    statRow(L("Daily average", comment: "Settings row: mean spend per completed day"),
                            ClaudeUsageReader.fmtMoney(m.dailyAverage))
                    divider
                    statRow(L("Projected month end", comment: "Settings row: what the month is on course to cost"),
                            ClaudeUsageReader.fmtMoney(m.projectedTotal))
                }
            }
            if let m = monthly {
                Text(String(format: L("Projected from %1$d day(s) of spend, with %2$d still to go. Estimated at public API prices, not your subscription bill.",
                                      comment: "Caveat under the spend projection. %1$d is days measured, %2$d is days remaining"),
                            m.daysMeasured, m.daysRemaining))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
