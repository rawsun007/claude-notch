import AppKit

// The menu's read-only reporting: today's usage, the spend rows and the little
// contribution heatmap. Split out of MenuBarController.swift, which held the
// status item, every submenu and all the rendering in one file.

extension MenuBarController {
    func refreshInsights() {
        insightsMenu.removeAllItems()
        let s = state.stats

        func row(_ title: String, enabled: Bool = false) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = enabled
            insightsMenu.addItem(mi)
        }

        // Daily digest — shown once per day when yesterday had activity.
        if state.shouldShowDigest {
            if let spend = state.yesterdaySpend {
                let cost = String(format: "$%.2f", spend.costUSD)
                let sessions = spend.sessionCount == 1 ? "1 session" : "\(spend.sessionCount) sessions"
                var line = "🌙  Yesterday: \(cost)  ·  \(sessions)"
                if !spend.topProject.isEmpty { line += "  ·  \(spend.topProject)" }
                row(line)
            } else if let y = state.yesterdayCounts {
                row("🌙  Yesterday: \(y.tools) tools  ·  \(y.allowed) allowed  ·  \(y.denied) denied")
            }
            let dismiss = NSMenuItem(title: "Dismiss digest", action: #selector(dismissDigest), keyEquivalent: "")
            dismiss.target = self
            insightsMenu.addItem(dismiss)
            insightsMenu.addItem(.separator())
        }

        if let t = state.stats.dailyCounts[AppState.dayKey(Date())] {
            row("Today:  \(t.tools) tools  ·  \(t.allowed) allowed  ·  \(t.denied) denied")
        } else {
            row("Today:  no activity yet")
        }
        row("This session:  \(state.sessionTools) tools · \(state.sessionAllowed) allowed · \(state.sessionDenied) denied")
        insightsMenu.addItem(.separator())
        row("Approved:  \(s.allowed)   (\(s.autoApproved) auto)")
        row("Denied:  \(s.denied)")
        row("Risky commands flagged:  \(s.dangerousFlagged)")
        row("Questions answered:  \(s.questionsAnswered)")

        let top = s.toolCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
        if !top.isEmpty {
            insightsMenu.addItem(.separator())
            row("Most-used tools")
            for (tool, n) in top { row("    \(tool):  \(n)") }
        }

        insightsMenu.addItem(.separator())
        row("Active days:  \(state.activeDayCount)    ·    Streak:  \(state.currentStreak)🔥")
        if let first = s.firstUsed {
            let df = DateFormatter()
            df.dateStyle = .medium
            row("Using ClaudeNotch since \(df.string(from: first))")
        }

        insightsMenu.addItem(.separator())
        appendHeatmap()
    }

    func renderClaudeUsage() {
        claudeUsageMenu.removeAllItems()
        func row(_ title: String) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            claudeUsageMenu.addItem(mi)
        }
        func monoRow(_ title: String) {
            let mono = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.attributedTitle = NSAttributedString(string: title, attributes: [.font: mono])
            claudeUsageMenu.addItem(mi)
        }
        guard let u = cachedClaudeUsage else {
            row(claudeUsageComputing ? "Computing…" : "No usage data yet")
            return
        }
        guard u.hasData else {
            row("No Claude usage in the last 7 days")
            return
        }
        let tk = ClaudeUsageReader.fmtTokens
        let mn = ClaudeUsageReader.fmtMoney
        if u.today.total > 0 {
            row("Today:  \(tk(u.today.total)) tokens  ·  ~\(mn(u.today.costUSD))")
            if u.todayVsAverage > 0 {
                row(String(format: "    %.1f× your daily average", u.todayVsAverage))
            }
        } else {
            row("Today:  no activity yet")
        }
        row("This week:  \(tk(u.week.total)) tokens  ·  ~\(mn(u.week.costUSD))")

        // 7-day token sparkline.
        let spark = ClaudeUsageReader.sparkline(daily: u.dailyTokens)
        claudeUsageMenu.addItem(.separator())
        row("Tokens, last 7 days")
        monoRow("    " + spark.bars)
        monoRow("    " + spark.labels)

        claudeUsageMenu.addItem(.separator())
        if u.sessionsWeek > 0 {
            row("Sessions (7 days):  \(u.sessionsWeek)  ·  ~\(tk(u.avgTokensPerSession))/session")
        }
        if u.cacheHitRate > 0 {
            row("Cache:  \(Int((u.cacheHitRate * 100).rounded()))% reused  ·  saved ~\(mn(u.cacheSavingsUSD))")
        }
        if !u.topHours.isEmpty {
            row("Busiest:  " + u.topHours.map { ClaudeUsageReader.hourLabel($0) }.joined(separator: "  ·  "))
        }

        let byModel = u.weekByModel.sorted { $0.value.total != $1.value.total ? $0.value.total > $1.value.total : $0.key < $1.key }
        if !byModel.isEmpty {
            claudeUsageMenu.addItem(.separator())
            row("By model (7 days)")
            for (model, t) in byModel {
                row("    \(model):  \(tk(t.total))  ·  ~\(mn(t.costUSD))")
            }
        }

        // Sorted by cost (most expensive repos first), since that's what you
        // usually want to know.
        let byProject = u.weekByProject.sorted { $0.value.costUSD != $1.value.costUSD ? $0.value.costUSD > $1.value.costUSD : $0.key < $1.key }.prefix(6)
        if !byProject.isEmpty {
            claudeUsageMenu.addItem(.separator())
            row("Top projects by cost (7 days)")
            for (cwd, t) in byProject {
                row("    \(ClaudeUsageReader.projectName(cwd)):  ~\(mn(t.costUSD))  ·  \(tk(t.total))")
            }
        }

        claudeUsageMenu.addItem(.separator())
        row("Est. cost if billed at public API rates")
    }

    /// Append a 7×7 text heatmap of the last 49 days to the Insights submenu.
    private func appendHeatmap() {
        let symbols = ["·", "▫", "▪", "▣", "■"]
        let mono = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let header = NSMenuItem(title: "Activity, last 7 weeks", action: nil, keyEquivalent: "")
        header.isEnabled = false
        insightsMenu.addItem(header)

        let cal = Calendar.current
        var grid: [[Int]] = Array(repeating: Array(repeating: 0, count: 7), count: 7)
        for i in 0..<49 {
            guard let day = cal.date(byAdding: .day, value: -(48 - i), to: Date()) else { continue }
            let n = state.stats.dailyCounts[AppState.dayKey(day)]?.tools ?? 0
            let level: Int
            switch n {
            case 0:      level = 0
            case 1...5:  level = 1
            case 6...15: level = 2
            case 16...30: level = 3
            default:     level = 4
            }
            grid[i / 7][i % 7] = level
        }

        for row in grid {
            let s = "    " + row.map { symbols[$0] }.joined(separator: "  ")
            let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.attributedTitle = NSAttributedString(string: s, attributes: [.font: mono])
            insightsMenu.addItem(mi)
        }

        let legend = "    less  " + symbols.joined(separator: " ") + "  more"
        let leg = NSMenuItem(title: legend, action: nil, keyEquivalent: "")
        leg.isEnabled = false
        leg.attributedTitle = NSAttributedString(string: legend, attributes: [.font: mono])
        insightsMenu.addItem(leg)
    }
}
