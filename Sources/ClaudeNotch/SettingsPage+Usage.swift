import SwiftUI
import AppKit

// The Usage page: what the sessions cost, where the tokens went, and the export
// buttons that get it out of the app. Split out of SettingsWindow.swift, which
// held every page in one 2,400-line file; the pages are independent of each
// other, so they read better one concern per file, the way AppState is split.

extension SettingsView {
    var usage: some View {
        page(L("Usage", comment: "Settings page title")) {
            let churn = state.churnToday
            if churn.added > 0 || churn.removed > 0 {
                sectionLabel(L("Code churn today", comment: "Settings section heading"))
                HStack(spacing: 12) {
                    churnStat("Lines added", "+\(churn.added)", .green)
                    churnStat("Lines removed", "-\(churn.removed)", .red)
                    churnStat("Net", "\(churn.added - churn.removed >= 0 ? "+" : "")\(churn.added - churn.removed)", .primary)
                }
            }

            if let u = claudeUsage {
                let trend = spendTrendData(u)
                if trend.contains(where: { $0.cost > 0 }) {
                    sectionLabel(L("Estimated cost, last 7 days", comment: "Settings section heading"))
                    Text(L("Estimated at public API (pay-as-you-go) prices. On a Pro, Max, Team, or Enterprise subscription you pay a flat fee, so this is not your actual bill, it is what the usage would cost per token.", comment: "Settings explanation"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    spendTrend(trend)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardChrome()
                }
                let weekly = ClaudeUsageReader.weeklyCostBuckets(daily: u.dailyCostUSD, weeks: 4, asOf: Date())
                if weekly.contains(where: { $0.cost > 0 }) {
                    sectionLabel(L("Estimated cost, last 4 weeks", comment: "Settings section heading"))
                    spendTrend(weekly)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardChrome()
                }
            }

            sectionLabel(L("Activity, last 7 weeks", comment: "Settings section heading"))
            activityHeatmap
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardChrome()

            Text(L("All-time counters, kept locally on this Mac.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)
            group {
                statRow("Permissions allowed", "\(state.stats.allowed)")
                divider
                statRow("Permissions denied", "\(state.stats.denied)")
                divider
                statRow("Auto-approved", "\(state.stats.autoApproved)")
                divider
                statRow("Dangerous commands flagged", "\(state.stats.dangerousFlagged)")
                divider
                statRow("Questions answered", "\(state.stats.questionsAnswered)")
                divider
                statRow("Active days", "\(state.stats.activeDays.count)")
                divider
                statRow("Sessions recorded", "\(state.sessionHistory.count)")
            }
            if !state.stats.toolCounts.isEmpty {
                sectionLabel(L("Top tools", comment: "Settings section heading"))
                group {
                    let top = state.stats.toolCounts.sorted { $0.value > $1.value }.prefix(6)
                    ForEach(Array(top.enumerated()), id: \.element.key) { idx, kv in
                        statRow(kv.key, "\(kv.value)")
                        if idx < top.count - 1 { divider }
                    }
                }
            }

            let spendLeaders = state.weekCostByProject
                .filter { $0.value > 0 && AppState.isRealProject($0.key) }
                .sorted { $0.value > $1.value }
                .prefix(6)
            if !spendLeaders.isEmpty {
                sectionLabel(L("Top projects by estimated cost (7 days)", comment: "Settings section heading"))
                let maxSpend = spendLeaders.first?.value ?? 1
                group {
                    ForEach(Array(spendLeaders.enumerated()), id: \.element.key) { idx, kv in
                        spendLeaderRow(project: (kv.key as NSString).lastPathComponent,
                                       cost: kv.value, fraction: maxSpend > 0 ? kv.value / maxSpend : 0)
                        if idx < spendLeaders.count - 1 { divider }
                    }
                }
            }

            sectionLabel(L("Claude usage (from transcripts)", comment: "Settings section heading"))
            Text(L("Costs are estimates at public API prices, not your subscription bill.", comment: "Settings explanation"))
                .font(.caption).foregroundStyle(.secondary)
            if let u = claudeUsage {
                group {
                    statRow("Today", "\(formatTokens(u.today.total)) tok · \(usd(u.today.costUSD))")
                    divider
                    statRow("Last 5 hours", "\(formatTokens(u.fiveHour.total)) tok · \(usd(u.fiveHour.costUSD))")
                    divider
                    statRow("This week", "\(formatTokens(u.week.total)) tok · \(usd(u.week.costUSD))")
                    divider
                    statRow("Sessions this week", "\(u.sessionsWeek)")
                    divider
                    statRow("Cache hit rate", "\(Int(u.cacheHitRate * 100))%")
                    divider
                    statRow("Cache savings", usd(u.cacheSavingsUSD))
                }

                let models = u.weekByModel
                    .filter { $0.value.costUSD > 0 }
                    .sorted { $0.value.costUSD > $1.value.costUSD }
                if !models.isEmpty {
                    sectionLabel(L("Model mix (last 7 days)", comment: "Settings section heading"))
                    let maxCost = models.first?.value.costUSD ?? 1
                    group {
                        ForEach(Array(models.enumerated()), id: \.element.key) { idx, kv in
                            spendLeaderRow(project: kv.key, cost: kv.value.costUSD,
                                           fraction: maxCost > 0 ? kv.value.costUSD / maxCost : 0)
                            if idx < models.count - 1 { divider }
                        }
                    }
                }

                Button {
                    state.exportSessionHistory()
                } label: {
                    Label("Export session history (CSV)", systemImage: "square.and.arrow.up")
                }
                .padding(.top, 2)
            } else {
                Text(L("Reading transcripts…", comment: "Settings explanation")).font(.callout).foregroundStyle(.secondary)
            }

            // Shown whenever Codex is wired up, even at zero. Hiding the whole
            // section until the first session made "Codex is on but I see
            // nothing here" indistinguishable from a broken integration.
            if HookInstaller.isCodexInstalled {
                sectionLabel(L("Codex usage (tokens)", comment: "Settings section heading"))
                Text(L("Token counts from Codex rollouts. No dollar cost: gpt pricing isn't published, so a figure would be a guess.", comment: "Settings explanation"))
                    .font(.caption).foregroundStyle(.secondary)
                if let c = codexTotals, !c.isEmpty {
                    group {
                        statRow("Today", "\(formatTokens(c.todayTokens)) tok · \(c.sessionsToday) session\(c.sessionsToday == 1 ? "" : "s")")
                        divider
                        statRow("This week", "\(formatTokens(c.weekTokens)) tok · \(c.sessionsWeek) session\(c.sessionsWeek == 1 ? "" : "s")")
                    }
                } else if codexTotals == nil {
                    Text(L("Reading Codex sessions…", comment: "Settings explanation while Codex usage is being read"))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(L("No Codex usage in the last 7 days. Run a Codex session and it will appear here.", comment: "Settings explanation when Codex is on but unused"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: section) {
            guard section == SettingsSection.usage else { return }
            let codexOn = HookInstaller.isCodexInstalled
            let (usage, ctotals) = await Task.detached(priority: .utility) {
                (ClaudeUsageReader.compute(), codexOn ? CodexReader.tokenTotals() : nil)
            }.value
            claudeUsage = usage
            codexTotals = ctotals
        }
    }
}
