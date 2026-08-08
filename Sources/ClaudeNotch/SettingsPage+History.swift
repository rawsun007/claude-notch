import SwiftUI
import AppKit

// The History page: the activity log, its filters, and the archived session
// records behind it. Split out of SettingsWindow.swift for the same reason as
// the other pages.

extension SettingsView {
    var history: some View {
        page(L("History", comment: "Settings page title")) {
            Text(L("Every session you finish is archived here with a one-line summary, its cost, and what it changed. Search to recall what you did in a project last week.", comment: "Settings explanation"))
                .font(.callout).foregroundStyle(.secondary)

            if state.sessionHistory.isEmpty {
                group {
                    HStack {
                        Text(L("No finished sessions yet. They show up here after a session ends.", comment: "Settings explanation"))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                }
            } else {
                standupSection
                let total = state.sessionHistory.reduce(into: (cost: 0.0, add: 0, rem: 0)) { acc, r in
                    acc.cost += r.costUSD
                    acc.add += r.linesAdded ?? 0
                    acc.rem += r.linesRemoved ?? 0
                }
                HStack(spacing: 14) {
                    Text(state.sessionHistory.count == 1 ? L("1 session", comment: "Count of archived sessions, singular")
                         : String(format: L("%d sessions", comment: "Count of sessions being summarised"), state.sessionHistory.count))
                    Text(ClaudeUsageReader.fmtMoney(total.cost)).foregroundStyle(.secondary)
                    Text("+\(total.add)").foregroundStyle(.green)
                    Text("-\(total.rem)").foregroundStyle(.red)
                }
                .font(.callout.monospacedDigit())

                SearchField(placeholder: "Search by project, summary, branch…", text: $historySearch)

                let matches = filteredHistory
                if matches.isEmpty {
                    group {
                        HStack {
                            Text(String(format: L("No sessions match “%@”.", comment: "Empty search result. %@ is what was typed"), historySearch))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 10).padding(.horizontal, 14)
                    }
                } else {
                    group {
                        ForEach(Array(matches.prefix(100).enumerated()), id: \.element.id) { idx, r in
                            historyRow(r)
                            if idx < min(matches.count, 100) - 1 { divider }
                        }
                    }
                }

                HStack {
                    Button("Export…") { state.exportSessionHistory() }
                    Spacer()
                    Button("Clear history", role: .destructive) { state.clearSessionHistory() }
                        .foregroundStyle(.red)
                }
                .padding(.top, 2)
            }
        }
    }
}
