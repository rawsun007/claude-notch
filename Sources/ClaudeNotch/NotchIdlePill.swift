import SwiftUI
import AppKit

// The idle card (the notch's resting state) and the command line block.



// MARK: - Idle

struct IdlePill: View {
    @ObservedObject var state: AppState
    @State private var pulsePhase: Double = 0   // 0→2π, used by SessionsList

    private var canExpand: Bool { !state.fullClaudeResponse.isEmpty }
    private var canShowHistory: Bool { !state.history.isEmpty }
    private var isOpen: Bool { state.persistentNotchDisplay || state.isHovering }
    private var hasMultipleSessions: Bool { state.activeSessionCount >= 2 }

    private var nameText: String {
        hasMultipleSessions
            ? String(format: L("%1$@ · %2$d sessions",
                               comment: "Idle card title with more than one session. %1$@ is the agent name, %2$d is how many sessions"),
                     state.entityName, state.activeSessionCount)
            : state.entityName
    }

    private var statusText: String {
        if state.claudeActionStatus == "thinking" {
            return L("Thinking", comment: "Status: the agent is reasoning, not running a tool")
        }
        if state.isClaudeWorking {
            return L("Running command", comment: "Status: the agent is running a tool call")
        }
        return L("Ready", comment: "Status: the agent is idle and waiting")
    }

    /// VoiceOver reads the name and the status as one phrase, so the two are
    /// joined by a format string rather than concatenated in the view.
    private var statusAccessibilityLabel: String {
        String(format: L("Claude Code, %@", comment: "VoiceOver label for the status line. %@ is the status word"),
               statusText)
    }

    private var statusDotColor: Color {
        if state.isClaudeWorking { return .blue }
        if !state.lastClaudeResponse.isEmpty { return .green }
        return .gray
    }

    private var isActiveStatus: Bool { state.isClaudeWorking }

    @ViewBuilder
    private var statusLabelView: some View {
        if isActiveStatus {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
                let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2.5) / 2.5)
                Text(statusText)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Self.shimmerGradient(phase: phase))
                    .lineLimit(1)
                    .accessibilityLabel(statusAccessibilityLabel)
            }
        } else {
            Text(statusText)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.38))
                .lineLimit(1)
                .accessibilityLabel("Claude Code, \(statusText)")
        }
    }

    private func parseActivity(_ activity: String) -> (icon: String, text: String) {
        let parts = activity.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let toolName = parts.first ?? activity
        let argument = parts.count > 1 ? parts[1] : ""
        let icon: String
        switch toolName.lowercased() {
        case "bash":         icon = "terminal"
        case "edit":         icon = "pencil"
        case "write":        icon = "square.and.pencil"
        case "read":         icon = "doc.text"
        case "websearch":    icon = "magnifyingglass"
        case "webfetch":     icon = "globe"
        case "todowrite":    icon = "checklist"
        case "agent":        icon = "person.fill"
        case "notebookedit": icon = "book"
        case "skill":        icon = "wand.and.stars"
        default:             icon = "bolt.fill"
        }
        return (icon, argument.isEmpty ? toolName : argument)
    }

    // Sweeping shimmer: bright spot travels left→right. phase 0→1 maps position -0.3→1.3
    // so the highlight enters and exits the text cleanly with a natural pause at each end.
    static func shimmerGradient(phase: CGFloat, base: CGFloat = 0.32, peak: CGFloat = 0.72) -> LinearGradient {
        let pos = phase * 1.6 - 0.3
        let span: CGFloat = 0.22
        var stops: [Gradient.Stop] = [.init(color: .white.opacity(base), location: 0.0)]
        let lo = pos - span; let hi = pos + span
        if lo > 0.01 && lo < 0.99 { stops.append(.init(color: .white.opacity(base), location: lo)) }
        if pos > 0.01 && pos < 0.99 { stops.append(.init(color: .white.opacity(peak), location: pos)) }
        if hi > 0.01 && hi < 0.99 { stops.append(.init(color: .white.opacity(base), location: hi)) }
        stops.append(.init(color: .white.opacity(base), location: 1.0))
        return LinearGradient(stops: stops.sorted { $0.location < $1.location },
                              startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1 — Claude icon · name · status dot · status label · action buttons
            HStack(spacing: 6) {
                ClaudeIconView(size: 15, mood: state.petEnabled ? state.petMood : nil)
                Text(nameText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if canShowHistory { state.openHistory() }
                        else if canExpand { state.showResponseDetail() }
                    }
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 5, height: 5)
                    .opacity(isActiveStatus
                        ? 0.4 + 0.6 * (0.5 + 0.5 * sin(pulsePhase))
                        : 1.0)
                statusLabelView
                if let badge = permissionModeBadge(state.currentPermissionMode) {
                    Text(badge.label)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(badge.color.opacity(0.95))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.18))
                        .cornerRadius(4)
                        .help(badge.help)
                }
                // Secondary counts — shown whenever the card is open, whether
                // the cursor is on the notch or persistentNotchDisplay is
                // holding it open, so the two states show the same detail.
                if isOpen {
                    let agentCount = state.totalRunningAgentCount
                    if agentCount > 0 {
                        Text(agentCount == 1
                             ? L("1 agent", comment: "Badge: exactly one background agent is running")
                             : String(format: L("%d agents", comment: "Badge: how many background agents are running"), agentCount))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.purple.opacity(0.95))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.18))
                            .cornerRadius(4)
                    }
                    let fileCount = state.currentTouchedFiles.count
                    if fileCount > 0 {
                        Text(fileCount == 1
                             ? L("1 file", comment: "Badge: exactly one file was edited this session")
                             : String(format: L("%d files", comment: "Badge: how many files were edited this session"), fileCount))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.cyan.opacity(0.95))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.15))
                            .cornerRadius(4)
                            .help(L("Files Claude edited this session, full list in the menu bar",
                                    comment: "Tooltip on the edited-files badge"))
                    }
                }
                Spacer(minLength: 0)
                if canShowHistory {
                    Button { state.openHistory() } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help(L("Show history", comment: "Tooltip: open the activity history panel"))
                    .accessibilityLabel(L("Show history", comment: "Tooltip: open the activity history panel"))
                }
                if canExpand {
                    Button { state.showResponseDetail() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help(L("Expand response", comment: "Tooltip: show the agent's full reply"))
                    .accessibilityLabel(L("Expand response", comment: "Tooltip: show the agent's full reply"))
                }
            }

            // Row 2 — the TOP (most-recently-active) session's model + meter,
            // read from that one session object so model/context/cost/branch are
            // coherent (no mixing the drifting global mirrors across agents).
            let top = state.primarySession
            let topModel = top?.model ?? state.currentModel
            let isClaudeTop = AgentKind.infer(fromModel: topModel) == .claude
            let (modelName, modelVer) = ClaudeUsageReader.modelNameVersion(topModel)
            let topBranch = top?.gitBranch ?? state.currentGitBranch
            let effort = isClaudeTop ? state.currentEffort : ""   // effort is a Claude concept
            HStack(spacing: 5) {
                if !modelName.isEmpty {
                    // One text run, not two views in a spaced HStack. "Opus"
                    // and "5" sat 5pt apart with the version dimmer, which read
                    // as two unrelated stats rather than the model's name. The
                    // version keeps its lighter weight, it just stops being a
                    // separate column.
                    (Text(modelName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                     + ((isOpen && !modelVer.isEmpty)
                        ? Text(" \(modelVer)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.45))
                        : Text("")))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if isOpen {
                        if !effort.isEmpty {
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 2.5, height: 2.5)
                        }
                    }
                }
                if isOpen {
                    if !effort.isEmpty {
                        Text(String(format: L("%@ effort", comment: "Reasoning effort label. %@ is a level such as high"), effort))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if !topBranch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                            Text(NotchView.elide(topBranch, to: 12))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .help(String(format: L("Checked-out git branch: %@",
                                               comment: "Tooltip on the branch chip. %@ is the branch name"), topBranch))
                    }
                    // What /add-dir granted this session on top of its folder.
                    // The header is the ONLY place a single-session user ever
                    // sees their session, so without this the chip existed
                    // only for people running two at once.
                    AddedDirsChip(paths: top?.addedDirectories ?? [],
                                  iconSize: 8, textSize: 10)
                }
                Spacer(minLength: 0)
                ContextCostBar(
                    percent: top?.contextPercent ?? state.currentContextPercent,
                    cost: top?.displayCostUSD ?? state.currentCostUSD,
                    model: topModel,
                    showModelName: false,   // row 2 already names it
                    costCap: state.sessionCostCap,
                    tokens: top?.contextTokens ?? state.currentContextTokens,
                    window: AppState.windowFor(model: topModel,
                                               reported: top?.contextWindow ?? state.currentContextWindow,
                                               learned: state.learnedContextWindows,
                                               tokens: top?.contextTokens ?? state.currentContextTokens,
                                               mode: state.contextWindowMode),
                    costIsReported: (top?.reportedCostUSD ?? 0) > 0
                )
                .layoutPriority(1)
            }

            // Row 3 — command strip, visible only while Claude is active
            if state.isClaudeWorking && !state.lastActivity.isEmpty {
                let parsed = parseActivity(state.lastActivity)
                CommandLineBlock(icon: parsed.icon, text: parsed.text,
                                 startedAt: state.activityStartedAt)
            }

            // Task-list progress — a thin bar showing how far through the
            // current task list Claude is, shown whenever the card is open and
            // there is a list.
            // Only worth a bar for a real multi-step list — a lone 1/1 task is
            // just a full green bar that says nothing.
            // Top task bar is strictly the top (primary) session's list, so it
            // never duplicates a secondary row's bar.
            let progress = state.primaryTaskProgress
            if isOpen, progress.total > 1 {
                let done = min(progress.done, progress.total)
                let frac = Double(done) / Double(progress.total)
                HStack(spacing: 6) {
                    Image(systemName: done >= progress.total ? "checkmark.circle.fill" : "checklist")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(done >= progress.total ? .green.opacity(0.8) : .white.opacity(0.5))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(done >= progress.total ? Color.green : Color(red: 0.29, green: 0.56, blue: 1.0))
                                .frame(width: max(3, geo.size.width * frac))
                        }
                    }
                    .frame(height: 4)
                    Text("\(done)/\(progress.total)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize()
                }
            }

            if isOpen && hasMultipleSessions {
                SessionsList(state: state, pulsePhase: pulsePhase)
            }

            // The limits are NOT here. They lived in the collapsed notch, where
            // they truncated to "8…" because it is only as wide as the hardware
            // cutout, and then in this hover card, where they made a glanceable
            // two-line pill into a three-line dashboard. They belong in the
            // history panel (the clock icon), which is where you go when you
            // actually want the numbers.
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                pulsePhase = .pi * 2
            }
        }
    }
}

// MARK: - Command line block

struct CommandLineBlock: View {
    let icon: String
    let text: String
    var startedAt: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
            let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.5) / 2.5)
            let border = IdlePill.shimmerGradient(phase: phase, base: 0.07, peak: 0.28)
            // How long the running tool has been going. The single most asked-for
            // thing about a long agent run is "is it stuck or still working" — a
            // ticking timer answers it at a glance. Once it passes a minute it
            // warms to amber, so a genuinely long run stands out from a quick one.
            let running = startedAt.map { tl.date.timeIntervalSince($0) }
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let running, running >= 1 {
                    Text(AppState.runningDuration(seconds: running))
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                        .foregroundColor((running >= 60 ? Color.orange : .white).opacity(0.5))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(border, lineWidth: 0.5)
                    )
            )
        }
    }
}
