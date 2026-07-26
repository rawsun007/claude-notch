import SwiftUI
import AppKit

// The history drawer: activity, session, and per-project rows.



// MARK: - History drawer

/// Outcome buckets the history drawer can filter by. `.all` short-circuits;
/// the rest match a single HistoryEntry.Outcome family.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, allowed, denied, dangerous, questions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:        return "All"
        case .allowed:    return "Allowed"
        case .denied:     return "Denied"
        case .dangerous:  return "Risky"
        case .questions:  return "Q&A"
        }
    }
    func matches(_ e: HistoryEntry) -> Bool {
        switch self {
        case .all:        return true
        case .allowed:    if case .allowed   = e.outcome { return true }; return false
        case .denied:     if case .denied    = e.outcome { return true }; return false
        case .dangerous:  if case .dangerous = e.outcome { return true }; return false
        case .questions:  if case .answered  = e.outcome { return true }; return false
        }
    }
}

enum HistoryTab: String, CaseIterable {
    case sessions = "Sessions"
    case projects = "Projects"
    case events   = "Events"
}

struct ProjectStats: Identifiable {
    let id: String          // project name
    let project: String
    let cwd: String
    let sessionCount: Int
    let totalCostUSD: Double
    let totalTokens: Int
    let totalToolCalls: Int
    let totalDuration: TimeInterval
    let lastSessionAt: Date
}

struct HistoryCard: View {
    @ObservedObject var state: AppState
    @State private var tab: HistoryTab = .sessions
    @State private var search = ""
    @State private var filter: HistoryFilter = .all
    @FocusState private var searchFocused: Bool

    private var filteredEvents: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.history.filter { e in
            guard filter.matches(e) else { return false }
            guard !q.isEmpty else { return true }
            return e.toolName.lowercased().contains(q)
                || e.title.lowercased().contains(q)
                || e.detail.lowercased().contains(q)
                || e.project.lowercased().contains(q)
        }
    }

    private var filteredSessions: [SessionRecord] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return state.sessionHistory }
        return state.sessionHistory.filter {
            $0.project.lowercased().contains(q) || $0.cwd.lowercased().contains(q)
        }
    }

    private var allProjectStats: [ProjectStats] {
        var grouped: [String: [SessionRecord]] = [:]
        // A run in a temp directory is real work, but it is not a project: it sits
        // in this list next to a repo you have spent a fortnight in, and it will
        // not exist tomorrow.
        for r in state.sessionHistory where AppState.isRealProject(r.cwd) {
            grouped[r.project, default: []].append(r)
        }
        return grouped.map { project, records in
            let cwd = records.first?.cwd ?? ""
            return ProjectStats(
                id: project,
                project: project,
                cwd: cwd,
                sessionCount: records.count,
                // Money comes from the transcripts, not from the session records —
                // see AppState.weekCostByProject for why the records cannot be
                // trusted for it. Both this figure and the header above are the
                // last seven days, so they agree.
                totalCostUSD: state.weekCostByProject[cwd] ?? 0,
                totalTokens: records.reduce(0) { $0 + $1.contextTokens },
                totalToolCalls: records.reduce(0) { $0 + $1.toolCallCount },
                totalDuration: records.compactMap(\.duration).reduce(0, +),
                lastSessionAt: records.map(\.startedAt).max() ?? .distantPast
            )
        }
        .sorted { $0.lastSessionAt > $1.lastSessionAt }
    }

    private var filteredProjects: [ProjectStats] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allProjectStats }
        return allProjectStats.filter { $0.project.lowercased().contains(q) }
    }

    /// Cost per day for the trailing week (oldest first) + totals. Powers the
    /// mini trend header on the Projects tab.
    ///
    /// Every number here comes from the transcripts, so the bars, the total and
    /// the project rows below all agree. The bars used to be built from the
    /// session records, which only exist for sessions the app was running for and
    /// archived — so a week of real work rendered as one tall bar today and six
    /// flat ones.
    private var weekSpend: (total: Double, sessions: Int, daily: [Double]) {
        let cal = Calendar.current
        let today = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let daily: [Double] = (0..<7).map { i in
            guard let day = cal.date(byAdding: .day, value: i - 6, to: today) else { return 0 }
            return state.weekCostByDay[fmt.string(from: day)] ?? 0
        }
        let total = state.weekCostByProject.values.reduce(0, +)
        return (total, state.sessionHistory.count, daily)
    }

    @ViewBuilder
    private var weekSpendHeader: some View {
        let w = weekSpend
        if w.sessions > 0 {
            HStack(spacing: 10) {
                // Mini 7-day bar chart, today rightmost.
                let peak = w.daily.max() ?? 0
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(i == 6 ? Color.green.opacity(0.9) : Color.green.opacity(0.45))
                            .frame(width: 5,
                                   height: peak > 0 ? max(2, 16 * w.daily[i] / peak) : 2)
                    }
                }
                .frame(height: 16, alignment: .bottom)
                Text("Last 7 days: \(ClaudeUsageReader.fmtMoney(w.total))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                Text("·").foregroundColor(.white.opacity(0.3))
                Text("\(w.sessions) session\(w.sessions == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.green.opacity(0.08))
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            limitsRow
            tabPicker
            searchField
            if tab == .events { filterChips }
            list
            footer
        }
        .onAppear { searchFocused = true }
    }

    /// Plan limits and session cost. This is the screen you open when you want
    /// the numbers, so this is where they live — with room to print the reset
    /// countdowns in full rather than squeezing them into the notch.
    @ViewBuilder
    private var limitsRow: some View {
        StatusBarRow(state: state)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: tabIcon)
                .foregroundColor(.white.opacity(0.85))
                .font(.system(size: 13, weight: .semibold))
            Text(tabTitle)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .textCase(.uppercase)
            Text("·").foregroundColor(.white.opacity(0.3))
            Text(countLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            if tab == .sessions {
                Button("Export") { state.exportSessionHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .disabled(state.sessionHistory.isEmpty)
                Text("·").foregroundColor(.white.opacity(0.2))
                Button("Clear") { state.clearSessionHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .disabled(state.sessionHistory.isEmpty)
            } else if tab == .events {
                Button("Export") { state.exportHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .disabled(state.history.isEmpty)
                Text("·").foregroundColor(.white.opacity(0.2))
                Button("Clear") { state.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .disabled(state.history.isEmpty)
            }
        }
    }

    private var tabIcon: String {
        switch tab {
        case .sessions: return "list.bullet.rectangle.portrait"
        case .projects: return "chart.bar.fill"
        case .events:   return "clock.arrow.circlepath"
        }
    }
    private var tabTitle: String {
        switch tab {
        case .sessions: return "Sessions"
        case .projects: return "Projects"
        case .events:   return "Activity"
        }
    }

    private var countLabel: String {
        switch tab {
        case .sessions:
            let n = filteredSessions.count
            return "\(n) session\(n == 1 ? "" : "s")"
        case .projects:
            let n = filteredProjects.count
            return "\(n) project\(n == 1 ? "" : "s")"
        case .events:
            let total = state.history.count
            let shown = filteredEvents.count
            return shown == total ? "\(total) event\(total == 1 ? "" : "s")" : "\(shown) of \(total)"
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 6) {
            ForEach(HistoryTab.allCases, id: \.rawValue) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(tab == t ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(tab == t
                                ? Color.white.opacity(0.9)
                                : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            TextField(tab == .events ? "Search tool, command, project…" : "Search project…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(HistoryFilter.allCases) { f in
                Button { filter = f } label: {
                    Text(f.label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(filter == f ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(filter == f
                                ? Color.white.opacity(0.9)
                                : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var list: some View {
        switch tab {
        case .sessions:
            if filteredSessions.isEmpty {
                emptyLabel(state.sessionHistory.isEmpty
                    ? "No sessions yet — completed sessions will appear here."
                    : "No sessions match your search.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(filteredSessions) { record in
                            SessionHistoryRow(record: record, onResume: { resume(record: record) })
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        case .projects:
            if filteredProjects.isEmpty {
                emptyLabel(state.sessionHistory.isEmpty
                    ? "No sessions yet — run some Claude sessions to see per-project stats."
                    : "No projects match your search.")
            } else {
                let maxCost = filteredProjects.map(\.totalCostUSD).max() ?? 0
                VStack(spacing: 6) {
                    weekSpendHeader
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(filteredProjects) { stats in
                                ProjectStatsRow(stats: stats, maxCost: maxCost,
                                                onResume: { resume(in: stats.cwd) })
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        case .events:
            if filteredEvents.isEmpty {
                emptyLabel(state.history.isEmpty
                    ? "Nothing yet — permissions and questions you resolve will show up here."
                    : "No events match your search.")
            } else {
                ScrollView {
                    VStack(spacing: 4) { ForEach(filteredEvents) { HistoryRow(entry: $0) } }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }

    /// Start a fresh Claude session in the given directory and close the panel.
    private func resume(in cwd: String) {
        guard !cwd.isEmpty else { return }
        state.closeHistory()
        TerminalAutomator.startClaude(in: cwd)
    }

    /// Resume the exact session behind a history row: when its key is a real
    /// session id (a UUID, not a cwd), reopen it with the matching CLI's resume;
    /// else fall back to starting that CLI fresh in the directory.
    private func resume(record: SessionRecord) {
        guard !record.cwd.isEmpty else { return }
        state.closeHistory()
        let key = record.sessionKey
        if !key.isEmpty, !key.contains("/") {
            TerminalAutomator.resume(model: record.model, sessionId: key, in: record.cwd)
        } else if AgentKind.infer(fromModel: record.model) == .codex {
            TerminalAutomator.startCodex(in: record.cwd)
        } else {
            TerminalAutomator.startClaude(in: record.cwd)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            NotchButton(label: "Close", style: .primary, shortcut: "⏎") {
                state.closeHistory()
            }
        }
        .padding(.top, 18)
    }
}

// MARK: - Session history row

struct SessionHistoryRow: View {
    let record: SessionRecord
    var onResume: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 22, height: 22)
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.blue.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.project)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if hovering, let onResume, !record.cwd.isEmpty {
                        Button(action: onResume) {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("Resume")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.green.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .help("Start Claude in \(record.cwd)")
                    } else {
                        Text(timeAgo(record.startedAt))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                HStack(spacing: 8) {
                    if let dur = record.duration {
                        label(fmtDuration(dur), icon: "clock")
                    }
                    if record.contextTokens > 0 {
                        label(fmtK(record.contextTokens) + " tok", icon: "text.alignleft")
                    }
                    if record.costUSD > 0 {
                        label(ClaudeUsageReader.fmtMoney(record.costUSD), icon: "dollarsign")
                    }
                    if record.toolCallCount > 0 {
                        label("\(record.toolCallCount) tools", icon: "wrench.and.screwdriver")
                    }
                }
                if !record.model.isEmpty {
                    let m = ClaudeUsageReader.shortModel(record.model)
                    if !m.isEmpty, m != "unknown" {
                        Text(m)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
        )
        .onHover { hovering = $0 }
        .help(record.cwd)
    }

    private func label(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
            Text(text)
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private func fmtK(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }

    private func fmtDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        let m = s / 60; let rem = s % 60
        if m < 60 { return rem > 0 ? "\(m)m \(rem)s" : "\(m)m" }
        let h = m / 60; let rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }
}

// MARK: - Project stats row

struct ProjectStatsRow: View {
    let stats: ProjectStats
    let maxCost: Double
    var onResume: (() -> Void)? = nil
    @State private var hovering = false

    private func fmtK(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }

    private func fmtDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60; let rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 22, height: 22)
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.green.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(stats.project)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if hovering, let onResume, !stats.cwd.isEmpty {
                        Button(action: onResume) {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("Resume")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.green.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .help("Start Claude in \(stats.cwd)")
                    } else {
                        Text("\(stats.sessionCount) session\(stats.sessionCount == 1 ? "" : "s")")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                HStack(spacing: 8) {
                    statChip(fmtDuration(stats.totalDuration), icon: "clock")
                    if stats.totalTokens > 0 {
                        statChip(fmtK(stats.totalTokens) + " tok", icon: "text.alignleft")
                    }
                    if stats.totalCostUSD > 0 {
                        statChip(ClaudeUsageReader.fmtMoney(stats.totalCostUSD), icon: "dollarsign")
                    }
                    if stats.totalToolCalls > 0 {
                        statChip("\(stats.totalToolCalls) tools", icon: "wrench.and.screwdriver")
                    }
                }
                if maxCost > 0, stats.totalCostUSD > 0 {
                    let frac = CGFloat(min(1, stats.totalCostUSD / maxCost))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(Color.green.opacity(0.6))
                                .frame(width: geo.size.width * frac)
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
        )
        .onHover { hovering = $0 }
        .help(stats.cwd)
    }

    private func statChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
            Text(text)
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundColor(.white.opacity(0.55))
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(outcomeColor.opacity(0.20)).frame(width: 22, height: 22)
                Image(systemName: outcomeIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(outcomeColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.toolName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                    if !entry.project.isEmpty {
                        Text(entry.project)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Spacer()
                    Text(timeAgo(entry.timestamp))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !entry.title.isEmpty {
                    Text(entry.title)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(outcomeLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(outcomeColor.opacity(0.95))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var outcomeColor: Color {
        switch entry.outcome {
        case .allowed:      return .green
        case .denied:       return .red
        case .dismissed:    return .gray
        case .answered:     return .purple
        case .info:         return .cyan
        case .dangerous:    return .orange
        }
    }
    private var outcomeIcon: String {
        switch entry.outcome {
        case .allowed:      return "checkmark"
        case .denied:       return "xmark"
        case .dismissed:    return "minus"
        case .answered:     return "arrow.right"
        case .info:         return "bell"
        case .dangerous:    return "exclamationmark.triangle.fill"
        }
    }
    private var outcomeLabel: String {
        switch entry.outcome {
        case .allowed:                  return "allowed"
        case .denied:                   return "denied"
        case .dismissed:                return "dismissed"
        case .answered(let n):          return "answered (\(n))"
        case .info:                     return entry.kind == .completed ? "completed" : "notification"
        case .dangerous:                return "allowed (destructive)"
        }
    }
}
