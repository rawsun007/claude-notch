import SwiftUI
import AppKit

// Multi-session list, task progress meter, and the context/cost bar.



// MARK: - Multi-session list

/// One tappable row per live Claude Code session — shown under the idle pill
/// when more than one session is active. Tapping a row opens the composer
/// pre-targeted at that session's project.
struct SessionsList: View {
    @ObservedObject var state: AppState
    var pulsePhase: Double

    /// Small CLI chip for a session row (CODEX / GROK). Claude is the default
    /// and shows nothing. Extracted to keep the row body cheap to type-check.
    @ViewBuilder
    static func agentTag(for model: String) -> some View {
        let agent = AgentKind.infer(fromModel: model)
        if agent != .claude {
            Text(agent.notchLabel.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.teal.opacity(0.95))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.teal.opacity(0.18))
                )
                .help("\(agent.displayName) session")
        }
    }

    var body: some View {
        // Exclude the top (primary) session: it is already shown as the header
        // meter above, so listing it here again is the duplication the user hit.
        let topID = state.primarySession?.id
        let secondary = state.activeSessions.filter { $0.id != topID }
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.bottom, 4)
            ForEach(secondary) { session in
                Button {
                    state.showSessionResponse(session)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            let working = AppState.isWorking(status: session.status)
                            Circle()
                                .fill(working ? Color.blue : Color.green)
                                .frame(width: 6, height: 6)
                                .opacity(working ? 0.4 + 0.6 * (0.5 + 0.5 * sin(pulsePhase)) : 1.0)
                            // The project is what you recognise a session BY. Claude
                            // Code names sessions itself now, so preferring the name
                            // meant a row saying "Caveman speech pattern impleme…"
                            // where the folder should have been — a title you never
                            // wrote, standing in for the one thing you would have
                            // recognised. The name is a subtitle, not the label.
                            //
                            // A background agent is the exception: it has no folder
                            // worth showing (it runs wherever it was dispatched) and
                            // the task it was given is genuinely its only name.
                            let isAgent = !session.backgroundAgentId.isEmpty
                            let label: String = {
                                if isAgent, !session.backgroundIntent.isEmpty { return session.backgroundIntent }
                                if !session.project.isEmpty { return session.project }
                                if !session.title.isEmpty { return session.title }
                                return "session"
                            }()
                            if !session.backgroundAgentId.isEmpty {
                                // A blocked agent is not just another running one:
                                // it has stopped, it is waiting on you, and nothing
                                // else on the machine will say so.
                                let blocked = session.agentNeedsInput
                                Text(blocked ? "AGENT WAITING" : "AGENT")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundColor((blocked ? Color.orange : .purple).opacity(0.95))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill((blocked ? Color.orange : Color.purple).opacity(0.18))
                                    )
                                    .help(blocked
                                          ? "This background agent is blocked waiting for you"
                                          : "Running in the background (claude --bg)")
                            }
                            // Which CLI this session belongs to. Claude is the
                            // default and stays untagged; other agents get a
                            // small chip so a mixed list is unambiguous.
                            Self.agentTag(for: session.model)
                            Text(label)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(session.cwd)
                            // Session title subtitle intentionally omitted from
                            // the row: it repeated the auto-derived name (e.g.
                            // "Caveman speech…") and cluttered the list. The
                            // project + branch identify the session; the full
                            // name is still available on the expanded view.
                            if !session.gitBranch.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 7, weight: .semibold))
                                    Text(NotchView.elide(session.gitBranch, to: 16))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.system(size: 9, design: .rounded))
                                .foregroundColor(.white.opacity(0.4))
                            }
                            // The mode this session is running in. The header badge
                            // only ever describes the CURRENT session, so a session
                            // in another project running with permissions bypassed
                            // was invisible — which is the one it is most important
                            // to be able to see.
                            if let badge = permissionModeBadge(session.permissionMode) {
                                Text(badge.label)
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundColor(badge.color.opacity(0.95))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(badge.color.opacity(0.18))
                                    )
                                    .help(badge.help)
                            }
                            // A background agent has no terminal of its own, so the
                            // only way to watch it or answer it is to attach.
                            if !session.backgroundAgentId.isEmpty {
                                Button {
                                    state.attachBackgroundAgent(id: session.backgroundAgentId,
                                                                cwd: session.cwd)
                                } label: {
                                    HStack(spacing: 2) {
                                        Image(systemName: "arrow.right.circle")
                                            .font(.system(size: 7, weight: .semibold))
                                        Text(L("Attach", comment: "Button: open a background agent in a terminal"))
                                            .font(.system(size: 9, weight: .medium, design: .rounded))
                                    }
                                    .foregroundColor(.purple.opacity(0.9))
                                }
                                .buttonStyle(.plain)
                                .help("Open this background agent in a terminal (claude attach \(session.backgroundAgentId))")
                                .accessibilityLabel("Attach to background agent")
                                .accessibilityHint("Opens it in a terminal")
                            }
                            // The open PR for this branch. Claude Code resolves it,
                            // so the notch can link straight to it instead of the
                            // app shelling out to `gh` to find out it exists.
                            if session.prNumber > 0 {
                                Button {
                                    // prURL is sanitized to http(s) at ingestion;
                                    // re-check the scheme here so this never opens
                                    // anything but a web link even if that changes.
                                    guard let url = URL(string: session.prURL),
                                          let scheme = url.scheme?.lowercased(),
                                          scheme == "http" || scheme == "https" else { return }
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    HStack(spacing: 2) {
                                        Image(systemName: "arrow.triangle.pull")
                                            .font(.system(size: 7, weight: .semibold))
                                        Text("#\(session.prNumber)")
                                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                                    }
                                    .foregroundColor(NotchView.prTint(session.prState))
                                }
                                .buttonStyle(.plain)
                                .disabled(session.prURL.isEmpty)
                                .help(NotchView.prTooltip(number: session.prNumber, state: session.prState))
                                .accessibilityLabel("Pull request \(session.prNumber)")
                                .accessibilityValue(session.prState)
                                .accessibilityHint("Opens the pull request in your browser")
                            }
                            // Two sessions in the same repo look identical in this
                            // list. The worktree is what tells them apart.
                            if !session.worktree.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "square.on.square")
                                        .font(.system(size: 7, weight: .semibold))
                                    Text(NotchView.elide(session.worktree, to: 14))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.system(size: 9, design: .rounded))
                                .foregroundColor(.white.opacity(0.4))
                                .help("Git worktree: \(session.worktree)")
                            }
                            if let waitStart = state.pendingWaitStart(forCwd: session.cwd) {
                                TimelineView(.periodic(from: .now, by: 15)) { _ in
                                    Text("⏳ \(waitElapsed(waitStart))")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundColor(.orange.opacity(0.95))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.18))
                                        .cornerRadius(4)
                                }
                                .help("Waiting for your answer")
                            }
                            if session.runningAgentCount > 0 {
                                Text(session.runningAgentCount == 1 ? "1 agent" : "\(session.runningAgentCount) agents")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundColor(.purple.opacity(0.95))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.18))
                                    .cornerRadius(4)
                            }
                            Spacer(minLength: 8)
                            if session.taskTotal > 0 {
                                TaskMeter(done: session.taskDone, total: session.taskTotal)
                            } else {
                                Text(session.status)
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        if session.isCompacting {
                            Text(L("compacting context…", comment: "Status: Claude is compacting its context window"))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundColor(.orange.opacity(0.8))
                                .padding(.leading, 14)
                        } else if session.hasMeter, session.id != state.currentSessionId {
                            // The header IS the current session, and it already shows
                            // this exact bar. Drawing it again a line below is not
                            // more information, it is the same number twice.
                            ContextCostBar(percent: session.contextPercent,
                                           cost: session.displayCostUSD,
                                           model: session.model,
                                           costCap: state.sessionCostCap,
                                           tokens: session.contextTokens,
                                           window: AppState.windowFor(model: session.model,
                                                                      reported: session.contextWindow,
                                                                      learned: state.learnedContextWindows,
                                                                      tokens: session.contextTokens,
                                                                      mode: state.contextWindowMode),
                                           costIsReported: session.reportedCostUSD > 0)
                                .padding(.leading, 14)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.fullResponse.isEmpty ? "No reply yet" : "Show \(session.project)'s last reply")
                // Merge the row's chips into the button rather than leaving a
                // dozen separate stops per session in a list that can hold 12.
                .accessibilityElement(children: .combine)
                .accessibilityHint(session.fullResponse.isEmpty ? "No reply yet" : "Shows the last reply")
            }
        }
    }
}

// MARK: - Task progress meter

/// Compact "N/M" task progress pill shown on a session row while a task list is
/// active. Turns green once every task is done.
struct TaskMeter: View {
    let done: Int
    let total: Int

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, max(0, CGFloat(done) / CGFloat(total)))
    }
    private var complete: Bool { total > 0 && done >= total }
    private var tint: Color { complete ? .green : .blue }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 26, height: 3)
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 26 * fraction, height: 3)
            }
            Text("\(done)/\(total)")
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(.white.opacity(complete ? 0.8 : 0.55))
                .lineLimit(1)
        }
        .help("\(done) of \(total) tasks done")
        // A capsule and "3/7" — the bar carries no meaning out loud and the
        // fraction reads as "three slash seven".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Task progress")
        .accessibilityValue("\(done) of \(total) tasks done")
    }
}

// MARK: - Context + cost meter

/// Compact context-window fill bar + running cost (and short model name) for a
/// session. The bar warms from blue to orange to red as the window fills, so a
/// near-full context (where Claude will soon compact) reads at a glance.
struct ContextCostBar: View {
    let percent: Double     // 0...1
    let cost: Double        // cumulative USD
    /// Needed even where the name isn't drawn: it's what sizes the window.
    var model: String = ""
    /// False where the row already names the model elsewhere.
    var showModelName: Bool = true
    var costCap: Double = 0 // session budget; 0 = off. Tints the cost figure.
    var tokens: Int = 0     // raw token count; 0 = omit token display
    /// The window Claude Code itself reported for this session. 0 = never
    /// reported (no status line yet), in which case the app falls back to
    /// inferring it from the model.
    var window: Int = 0
    /// True when `cost` is Claude Code's own reported figure rather than the
    /// app's transcript estimate. Only changes the tooltip wording.
    var costIsReported: Bool = false

    private var clamped: CGFloat { min(1, max(0, CGFloat(percent))) }
    private var costColor: Color {
        guard costCap > 0 else { return .white.opacity(0.4) }
        if cost >= costCap { return .red.opacity(0.95) }
        if cost >= costCap * 0.8 { return .orange.opacity(0.9) }
        return .white.opacity(0.4)
    }
    private var tint: Color {
        switch percent {
        case ..<0.6:  return .blue
        case ..<0.85: return .orange
        default:      return .red
        }
    }
    private var shortModel: String {
        let m = ClaudeUsageReader.shortModel(model)
        return m == "unknown" || m.isEmpty ? "" : m
    }
    private func fmtK(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        return n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
    private var maxTokens: Int {
        // Claude Code's own number wins over anything the app can work out.
        if window > 0 { return window }
        return ClaudeUsageReader.contextWindow(forModel: model, tokens: tokens, mode: .auto)
    }
    private var tokenLabel: String {
        guard tokens > 0 else { return "" }
        return "\(fmtK(tokens))/\(fmtK(maxTokens))"
    }
    private var tooltipText: String {
        let base = "Context \(Int((percent * 100).rounded()))% full"
        let tok  = tokens > 0 ? " · \(tokens.formatted()) / \(maxTokens.formatted()) tokens" : ""
        let cost: String
        if self.cost > 0 {
            cost = costIsReported
                ? " · \(ClaudeUsageReader.fmtMoney(self.cost)) this session (Claude Code's own figure)"
                : " · est. \(ClaudeUsageReader.fmtMoney(self.cost)) this session (estimated from the transcript)"
        } else {
            cost = ""
        }
        return base + tok + cost
    }

    var body: some View {
        HStack(spacing: 5) {
            if showModelName, !shortModel.isEmpty {
                Text(shortModel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 36, height: 3)
                Capsule().fill(tint.opacity(0.9)).frame(width: 36 * clamped, height: 3)
            }
            if !tokenLabel.isEmpty {
                Text(tokenLabel)
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundColor(tint.opacity(0.85))
                    // Half a context reading is worse than none: the row is tight
                    // enough that this used to truncate to "161k / 2…", which
                    // hides the one number that gives the other one meaning.
                    // It never truncates now — the labels left of it give way first.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            } else if percent > 0 {
                Text("\(Int((percent * 100).rounded()))%")
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundColor(.white.opacity(0.45))
            } else {
                // No status line yet: show an honest placeholder instead of a
                // misleading 0%, since 0% reads as "empty context" not "unknown".
                Text(L("no usage yet", comment: "Placeholder when a session has reported no token usage"))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.3))
            }
            if cost > 0 {
                Text(ClaudeUsageReader.fmtMoney(cost))
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundColor(costColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .help(tooltipText)
        // Same tooltip, spoken: the interpuncts the tooltip uses as separators
        // are read aloud as nothing at all, so they become sentence breaks.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context and cost")
        .accessibilityValue(tooltipText.replacingOccurrences(of: " · ", with: ". "))
    }
}
