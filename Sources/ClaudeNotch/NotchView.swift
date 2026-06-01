import SwiftUI
import AppKit

/// Carries the measured natural height of a compact card's content up to the
/// body so the card frame can be an EXPLICIT (animatable) height that exactly
/// matches the content — explicit so the spring interpolates it (grow-out-of-
/// notch), measured so it never clips or leaves dead space.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Drives the card's width/height with a plain Timer instead of SwiftUI's
/// `.animation`. SwiftUI's spring is display-link-driven and gets paused when
/// our app isn't frontmost (another app active / fullscreen) — so the card
/// "popped in" with no animation. A Timer keeps ticking as long as we hold a
/// ProcessInfo activity (App Nap disabled), so the size interpolates every
/// frame regardless of which app is active.
@MainActor
final class CardSizeAnimator: ObservableObject {
    @Published private(set) var width: CGFloat = 0
    @Published private(set) var height: CGFloat = 0

    private var timer: Timer?
    private var fromW: CGFloat = 0, fromH: CGFloat = 0
    private var toW: CGFloat = 0, toH: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.42
    private var overshoot = true

    /// Jump immediately (no animation) — used for the very first layout.
    func set(_ size: CGSize) {
        timer?.invalidate(); timer = nil
        width = size.width; height = size.height
        toW = size.width; toH = size.height
    }

    /// Animate toward a new size. `expanding` adds a slight overshoot for the
    /// grow-out-of-notch feel; collapsing eases in cleanly.
    func animate(to size: CGSize, expanding: Bool) {
        // Already there (and not mid-flight) → nothing to do.
        if abs(toW - size.width) < 0.5, abs(toH - size.height) < 0.5, timer == nil { return }
        fromW = width; fromH = height
        toW = size.width; toH = size.height
        overshoot = expanding
        duration = expanding ? 0.42 : 0.34
        start = CACurrentMediaTime()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        let raw = min(1, max(0, (CACurrentMediaTime() - start) / duration))
        let e = overshoot ? Self.easeOutBack(raw) : Self.easeOutCubic(raw)
        width  = fromW + (toW - fromW) * e
        height = fromH + (toH - fromH) * e
        if raw >= 1 {
            width = toW; height = toH
            timer?.invalidate(); timer = nil
        }
    }

    private static func easeOutCubic(_ t: Double) -> Double {
        let p = 1 - t
        return 1 - p * p * p
    }
    private static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = 1.70158 + 1
        let p = t - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }
}

struct NotchView: View {
    @ObservedObject var state: AppState
    @State private var compactHeight: CGFloat = 0
    @StateObject private var sizer = CardSizeAnimator()

    /// Horizontal breathing room between the card content and the notch's
    /// left/right edges. Tuned together with the bottom corner radius (~18 pt)
    /// so the bottom button row clears the curve. One knob for all cards.
    private let contentHorizontalPadding: CGFloat = 28

    /// How much vertical space is hidden by the physical notch (or 0 if none).
    static func notchInset(on screen: NSScreen?) -> CGFloat {
        guard let screen, screen.safeAreaInsets.top > 0 else { return 0 }
        return screen.safeAreaInsets.top
    }

    static func size(for mode: NotchMode, hovering: Bool = false, on screen: NSScreen? = nil) -> CGSize {
        let s = screen ?? NSScreen.main
        let inset = notchInset(on: s)
        // Rule of thumb: visible-height must be >= 2 * cornerRadius so the bottom
        // arc has straight side wall above it to flow out of (otherwise the
        // curve dominates the whole visible area and looks like a wedge).
        switch mode {
        case .idle:
            return hovering
                ? CGSize(width: 320, height: inset + 64)   // was 36 → curve had nowhere to go
                : collapsedSize(on: s)
        case .thinking:
            return CGSize(width: 340, height: inset + 64)
        case .permission(let req):
            if req.kind != .toolUse {
                // Notification card — generous fallback so it never clips
                // before the exact height is measured.
                return CGSize(width: 500, height: inset + 100)
            }
            // Tight content-fits sizing. Numbers calibrated against the
            // actual rendered rows (font + padding) — there is no Spacer in
            // the card any more, so the window IS the content size + padding.
            //   header row ........... 24
            //   title row ............ 22
            //   detail box (2 lines) . 42
            //   buttons row .......... 32
            //   four 8pt gaps ........ 32
            //   bottom card padding .. 12
            //                          ────
            //                          164
            var visible: CGFloat = 152
            if !req.dangerReasons.isEmpty {
                // Banner: 14pt of v-padding + 14pt header + 13pt per reason.
                visible += 28 + CGFloat(req.dangerReasons.count) * 14 + 8 // +8 gap
            }
            if let p = req.preview {
                switch p {
                case .diff(let h):
                    let total = min(ToolPreviewParser.maxDiffLines, h.oldLines.count)
                              + min(ToolPreviewParser.maxDiffLines, h.newLines.count)
                              + (h.truncatedOld || h.truncatedNew ? 1 : 0)
                    visible += CGFloat(total) * 14 + 16
                case .multiDiff(_, let h):
                    let total = min(8, h.oldLines.count) + min(8, h.newLines.count) + 1
                    visible += CGFloat(total) * 14 + 28
                case .write(_, let total):
                    visible += CGFloat(min(ToolPreviewParser.maxWriteLines, total)) * 14 + 16
                }
            }
            let screenH = s?.frame.height ?? 900
            let cap = max(180, screenH * 0.85 - inset)
            return CGSize(width: 620, height: inset + min(visible, cap))
        case .completed:
            return CGSize(width: 560, height: inset + 100)
        case .question(let q):
            // Header strip ≈ 30, button row ≈ 44, outer padding/spacing ≈ 30.
            // Each question heading ≈ 26 + 6 spacing; each option row ≈ 48
            // (icon + 12pt label + 10pt description + 5pt vertical padding ×2).
            let perOption: CGFloat = 48
            // +44 for the "Something else…" free-text row each question carries.
            let perQuestion: CGFloat = 26 + 6 + CGFloat(q.questions.first?.options.count ?? 1) * perOption + 44
            let want = 104 + CGFloat(q.questions.count) * perQuestion
            // Don't blow past the screen — leave at least 15% headroom so the
            // card stays usable on small displays. Only at that cap will the
            // inner scroll kick in.
            let screenH = s?.frame.height ?? 900
            let cap = max(360, screenH * 0.85 - inset)
            let visible = min(want, cap)
            return CGSize(width: 600, height: inset + visible)
        case .compose:
            return CGSize(width: 580, height: inset + 200)
        case .responseDetail:
            return CGSize(width: 660, height: inset + 360)
        case .history:
            // Reasonably tall drawer; cap at 70% of screen on small displays.
            let screenH = s?.frame.height ?? 900
            return CGSize(width: 640, height: min(inset + 460, screenH * 0.70))
        case .autoInfo:
            // Compact, button-less "live activity" card.
            return CGSize(width: 460, height: inset + 96)
        }
    }

    /// On notched MacBooks: match the physical notch so we visually merge.
    /// On non-notched Macs (Air, older): draw a Dynamic-Island-style fake notch
    /// of similar dimensions, hanging from the top.
    static func collapsedSize(on screen: NSScreen?) -> CGSize {
        if let screen,
           screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = max(160, right.minX - left.maxX)
            let height = max(28, screen.safeAreaInsets.top)
            return CGSize(width: width, height: height)
        }
        // No physical notch — fake one.
        return CGSize(width: 200, height: 30)
    }

    var body: some View {
        // The PANEL is a fixed large window. We draw the notch card pinned to
        // its top and animate the card's SIZE with SwiftUI springs — the
        // window itself never resizes, which is what makes the motion smooth
        // (no AppKit frame animation fighting SwiftUI) and kills the
        // "pops twice" double-relayout entirely.
        let card = NotchView.size(for: state.mode, hovering: isIdleOpen, on: NSScreen.main)
        let collapsed = isCollapsedIdle
        let shape = NotchShape(topCornerRadius: notchTopRadius,
                               bottomCornerRadius: notchBottomRadius)
        // The card height is an EXPLICIT value so the spring can interpolate
        // it (grow-out-of-notch). For compact cards it's the MEASURED content
        // height (never clips, no dead space); collapsed and scrollable modes
        // use the formula height.
        let displayHeight: CGFloat = {
            if collapsed || isScrollableMode { return card.height }
            return compactHeight > 1 ? compactHeight : card.height
        }()
        // The size we want the card to be. The Timer-driven `sizer`
        // interpolates toward it every frame (works in the background, unlike
        // SwiftUI's display-link animation). Use the sizer's current value for
        // the actual frame, falling back to the target before it's seeded.
        let target = CGSize(width: card.width, height: displayHeight)
        let w = sizer.width > 0 ? sizer.width : target.width
        let h = sizer.height > 0 ? sizer.height : target.height
        return ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if !collapsed {
                    // Lay the content out at its FINAL width/height (not the
                    // animating w/h) so it doesn't reflow as the card grows —
                    // the outer clip frame reveals it. Keeps the measured
                    // height stable (no animate↔measure feedback loop).
                    content
                        .frame(maxWidth: .infinity,
                               maxHeight: isScrollableMode ? .infinity : nil,
                               alignment: .top)
                        .padding(.horizontal, contentHorizontalPadding)
                        .padding(.top, state.notchTopInset + 10)
                        // Bottom padding only needs to clear the notch shape's
                        // bottom corner curve. Buttons are inset 22 pt
                        // horizontally so they sit above the straight edge.
                        // Pairs with the +18 top padding on each button row.
                        .padding(.bottom, 10)
                        .frame(width: card.width,
                               height: isScrollableMode ? card.height : nil,
                               alignment: .top)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ContentHeightKey.self,
                                    value: isScrollableMode ? 0 : g.size.height
                                )
                            }
                        )
                }
            }
            // Black fill + clip apply AT the animating frame size, so the
            // shape grows from the notch out to the card while the content
            // stays at full size underneath (revealed by the growing clip).
            .frame(width: w, height: h, alignment: .top)
            .background(Color.black)
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(collapsed ? 0 : 0.05), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { sizer.set(target) }
        .onPreferenceChange(ContentHeightKey.self) { h in
            if h > 1 { compactHeight = h }
        }
        .onChange(of: target) { newTarget in
            // expanding = growing toward a bigger card (overshoot for the
            // pop-out feel); collapsing eases in cleanly.
            let expanding = newTarget.width * newTarget.height >= (sizer.width * sizer.height)
            sizer.animate(to: newTarget, expanding: expanding)
        }
    }

    private var isCollapsedIdle: Bool {
        if case .idle = state.mode, !isIdleOpen { return true }
        return false
    }

    private var isIdleOpen: Bool {
        state.persistentNotchDisplay || state.isHovering
    }

    /// Modes that wrap a ScrollView and need a bounded (fixed) height so the
    /// scroll region doesn't collapse to zero (which blanked the question
    /// card) or run unbounded behind the notch.
    private var isScrollableMode: Bool {
        switch state.mode {
        case .history, .responseDetail, .question: return true
        default: return false
        }
    }


    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .idle:
            IdlePill(state: state)
                .transition(.opacity)
        case .thinking(let label):
            ThinkingPill(label: label)
                .transition(.opacity)
        case .permission(let req):
            if req.kind == .toolUse {
                PermissionCard(
                    request: req,
                    pendingCount: state.permissionQueue.count,
                    onResolve: { decision, scope in
                        state.resolveCurrentPermission(decision, alwaysAllow: scope)
                    },
                    onResolveAll: { decision in
                        state.resolveAllPermissions(decision)
                    },
                    onDenyReason: {
                        state.beginDenyReason(for: req)
                    },
                    useTouchID: state.requireTouchID && BiometricAuth.isAvailable
                )
                .transition(.opacity)
            } else {
                NotificationCard(request: req, onOpen: {
                    state.openOriginator(req.originatorBundleID)
                    state.resolveCurrentPermission(.ask)
                }, onDismiss: {
                    state.resolveCurrentPermission(.ask)
                })
                .transition(.opacity)
            }
        case .completed(let task):
            CompletedCard(task: task, onReply: {
                state.beginReply(to: task)
            }, onOpen: {
                state.openOriginator(task.originatorBundleID)
                state.dismissCurrentCompleted()
            }, onDismiss: {
                state.dismissCurrentCompleted()
            })
            .transition(.opacity)
        case .question(let req):
            QuestionCard(request: req, onSubmit: { answers in
                state.resolveCurrentQuestion(answers)
            }, onCancel: {
                state.resolveCurrentQuestion(nil)
            })
            .transition(.opacity)
        case .compose:
            ComposeCard(state: state)
                .transition(.opacity)
        case .responseDetail:
            ResponseDetailCard(state: state)
                .transition(.opacity)
        case .history:
            HistoryCard(state: state)
                .transition(.opacity)
        case .autoInfo(let req):
            AutoInfoCard(request: req) { state.dismissAutoInfo() }
                .transition(.opacity)
        }
    }

    /// Concave top-corner radius — the "ears" that blend the card into the
    /// menu bar / physical notch. Small when closed (≈ the real notch), a
    /// touch larger when open.
    private var notchTopRadius: CGFloat {
        isCollapsedIdle ? 9 : 12
    }

    /// Convex bottom-corner radius. Kept modest so the bottom button row
    /// (which sits ~24pt above the bottom edge) never collides with the
    /// corner curve and gets clipped.
    private var notchBottomRadius: CGFloat {
        if isCollapsedIdle { return 10 }
        switch state.mode {
        case .responseDetail, .history: return 22
        default:                        return 18
        }
    }

}

// MARK: - shared spec for IdlePill content

extension NotchView {
    fileprivate func idleSubtitle() -> String {
        if !state.lastClaudeResponse.isEmpty { return state.lastClaudeResponse }
        if !state.lastActivity.isEmpty { return state.lastActivity }
        if !state.lastUserPrompt.isEmpty { return state.lastUserPrompt }
        return "ready"
    }
}


// MARK: - Idle

private struct IdlePill: View {
    @ObservedObject var state: AppState
    @State private var pulsePhase: Double = 0   // 0→2π, used by SessionsList

    private var actionLabel: String {
        let s = state.claudeActionStatus
        guard !s.isEmpty else { return "ready" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private var canExpand: Bool { !state.fullClaudeResponse.isEmpty }
    private var canShowHistory: Bool { !state.history.isEmpty }
    private var isOpen: Bool { state.persistentNotchDisplay || state.isHovering }
    private var hasMultipleSessions: Bool { state.activeSessionCount >= 2 }

    private var nameText: String {
        hasMultipleSessions
            ? "\(AppState.statusEntityName) · \(state.activeSessionCount) sessions"
            : AppState.statusEntityName
    }

    private var dotColor: Color {
        if !state.lastClaudeResponse.isEmpty { return .green }
        if state.isClaudeWorking             { return .blue }
        return .gray
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
            // Row 1 — dot + name + session count + action buttons
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .opacity(state.isClaudeWorking
                        ? 0.4 + 0.6 * (0.5 + 0.5 * sin(pulsePhase))
                        : 1.0)
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
                Spacer(minLength: 0)
                if canShowHistory {
                    Button { state.openHistory() } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Show history")
                }
                if canExpand {
                    Button { state.showResponseDetail() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Expand response")
                }
            }

            // Row 2 — shimmer action label while working; last Claude message when idle.
            if state.isClaudeWorking {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
                    let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 2.5) / 2.5)
                    Text(actionLabel)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Self.shimmerGradient(phase: phase))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if !state.lastClaudeResponse.isEmpty {
                Text(state.lastClaudeResponse)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(actionLabel)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.38))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Row 3 — command strip, visible only while Claude is active
            if state.isClaudeWorking && !state.lastActivity.isEmpty {
                let parsed = parseActivity(state.lastActivity)
                CommandLineBlock(icon: parsed.icon, text: parsed.text)
            }

            // Single-session context + cost meter (multi-session shows it per row).
            if isOpen && !hasMultipleSessions
                && (state.currentContextPercent > 0 || state.currentCostUSD > 0) {
                ContextCostBar(percent: state.currentContextPercent,
                               cost: state.currentCostUSD,
                               model: state.currentModel,
                               costCap: state.sessionCostCap)
            }

            if isOpen && hasMultipleSessions {
                SessionsList(state: state, pulsePhase: pulsePhase)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                pulsePhase = .pi * 2
            }
        }
    }
}

// MARK: - Command line block

private struct CommandLineBlock: View {
    let icon: String
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
            let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.5) / 2.5)
            let border = IdlePill.shimmerGradient(phase: phase, base: 0.07, peak: 0.28)
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

// MARK: - Multi-session list

/// One tappable row per live Claude Code session — shown under the idle pill
/// when more than one session is active. Tapping a row opens the composer
/// pre-targeted at that session's project.
private struct SessionsList: View {
    @ObservedObject var state: AppState
    var pulsePhase: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.bottom, 4)
            ForEach(state.activeSessions) { session in
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
                            Text(session.project.isEmpty ? "session" : session.project)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.tail)
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
                            Text("compacting context…")
                                .font(.system(size: 9, design: .rounded))
                                .foregroundColor(.orange.opacity(0.8))
                                .padding(.leading, 14)
                        } else if session.hasMeter {
                            ContextCostBar(percent: session.contextPercent,
                                           cost: session.sessionCostUSD,
                                           model: session.model,
                                           costCap: state.sessionCostCap)
                                .padding(.leading, 14)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.fullResponse.isEmpty ? "No reply yet" : "Show \(session.project)'s last reply")
            }
        }
    }
}

// MARK: - Task progress meter

/// Compact "N/M" task progress pill shown on a session row while a task list is
/// active. Turns green once every task is done.
private struct TaskMeter: View {
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
    }
}

// MARK: - Context + cost meter

/// Compact context-window fill bar + running cost (and short model name) for a
/// session. The bar warms from blue to orange to red as the window fills, so a
/// near-full context (where Claude will soon compact) reads at a glance.
struct ContextCostBar: View {
    let percent: Double     // 0...1
    let cost: Double        // cumulative USD
    var model: String = ""
    var costCap: Double = 0 // session budget; 0 = off. Tints the cost figure.

    private var clamped: CGFloat { min(1, max(0, CGFloat(percent))) }
    /// Cost text color: warms toward red as the session nears/exceeds the cap.
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

    var body: some View {
        HStack(spacing: 5) {
            if !shortModel.isEmpty {
                Text(shortModel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 28, height: 3)
                Capsule().fill(tint.opacity(0.9)).frame(width: 28 * clamped, height: 3)
            }
            Text("\(Int((percent * 100).rounded()))%")
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundColor(.white.opacity(0.45))
            if cost > 0 {
                Text(ClaudeUsageReader.fmtMoney(cost))
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundColor(costColor)
            }
        }
        .help("Context window \(Int((percent * 100).rounded()))% full · est. \(ClaudeUsageReader.fmtMoney(cost)) this session")
    }
}

// MARK: - Compose

private struct ComposeCard: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    private var activeTerminalName: String {
        guard let bid = state.composeTarget else { return "no terminal" }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           let name = app.localizedName { return name }
        return bid
    }

    private var targetLabel: String {
        if let cwd = state.composeProjectCwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        // Reply: show the session's project alongside the terminal it runs in,
        // instead of just the terminal app name.
        if let ctx = state.composeContextLabel, !ctx.isEmpty {
            return "\(ctx) · \(activeTerminalName)"
        }
        return activeTerminalName
    }

    private var isDeny: Bool {
        if case .denyReason = state.composePurpose { return true }
        return false
    }
    private var accent: Color { isDeny ? .red : .cyan }
    private var headerIcon: String { isDeny ? "hand.raised.fill" : "paperplane.fill" }
    private var headerLabel: String { isDeny ? "Deny with a reason" : "Send to Claude" }
    private var placeholder: String {
        isDeny
            ? "tell Claude why, or what to do instead — ⌘↩ to deny, ⎋ to keep the prompt"
            : "type your message — ⌘↩ to send, ↩ for newline, ⎋ to cancel"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .foregroundColor(accent)
                    .font(.system(size: 13, weight: .semibold))
                Text(headerLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accent.opacity(0.9))
                    .textCase(.uppercase)
                Spacer()
                // Target picker: active terminal, or open a fresh terminal in
                // a recent project. Hidden when denying — there's no terminal
                // target, the note goes back to the waiting tool call.
                if !isDeny {
                Menu {
                    Button("Active terminal (\(activeTerminalName))") {
                        state.setComposeProject(nil)
                    }
                    if !state.recentProjects.isEmpty {
                        Divider()
                        Text("Open in project")
                        ForEach(state.recentProjects, id: \.self) { cwd in
                            Button((cwd as NSString).lastPathComponent) {
                                state.setComposeProject(cwd)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.composeProjectCwd != nil ? "folder.fill" : "terminal.fill")
                            .font(.system(size: 9))
                        Text("→ \(targetLabel)")
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                }
            }

            ZStack(alignment: .topLeading) {
                if state.composeText.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 14)
                        // TextEditor renders its first line / caret higher than a
                        // plain Text at the same top padding (the text view's own
                        // line metrics), so the placeholder sits ~7 to land on the
                        // caret's row rather than below it.
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $state.composeText)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)   // +5 lineFragment ≈ placeholder's 14
                    .padding(.top, 18)          // caret position; placeholder's top is tuned to match it
                    .padding(.bottom, 6)
                    .focused($focused)
            }
            .frame(minHeight: 80)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            if let err = state.composeError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                NotchButton(label: isDeny ? "Keep prompt" : "Cancel", style: .secondary, shortcut: "⎋") {
                    state.cancelCompose()
                }
                NotchButton(label: isDeny ? "Deny" : "Send", style: isDeny ? .destructive : .primary, shortcut: "⌘↩") {
                    state.sendCompose()
                }
            }
            .padding(.top, 18)
        }
        .onAppear {
            // Small delay — the panel needs a beat to fully become key before
            // SwiftUI focus can attach reliably.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focused = true
            }
        }
    }
}

// MARK: - Response detail

private struct ResponseDetailCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .semibold))
                Text("Claude's last reply")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.green.opacity(0.9))
                    .textCase(.uppercase)
                if !state.detailProject.isEmpty {
                    Text("·").foregroundColor(.white.opacity(0.3))
                    Text(state.detailProject)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parseMarkdownBlocks(state.detailResponseText).enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )

            HStack {
                Spacer()
                NotchButton(label: "Close", style: .primary, shortcut: "⏎") {
                    state.closeResponseDetail()
                }
            }
            .padding(.top, 18)
        }
    }
}

// MARK: - Thinking

private struct ThinkingPill: View {
    let label: String
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.3)).frame(width: 18, height: 18)
                Circle().fill(Color.blue).frame(width: 8, height: 8)
                    .scaleEffect(1 + 0.4 * sin(phase))
            }
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Permission (blocking, tool use)

private struct PermissionCard: View {
    let request: PermissionRequest
    var pendingCount: Int = 1
    let onResolve: (PermissionDecision, AllowScope) -> Void
    var onResolveAll: ((PermissionDecision) -> Void)? = nil
    var onDenyReason: (() -> Void)? = nil
    var useTouchID: Bool = false
    @State private var didArmTouchID = false

    private var accentColor: Color { request.isDangerous ? .red : .yellow }
    private var headerIcon: String { request.isDangerous ? "exclamationmark.triangle.fill" : "exclamationmark.bubble.fill" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .foregroundColor(accentColor)
                    .font(.system(size: 14, weight: .semibold))
                Text(request.source)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accentColor.opacity(0.9))
                    .textCase(.uppercase)
                Text("·").foregroundColor(.white.opacity(0.3))
                Text(request.toolName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                if !request.cwd.isEmpty {
                    Text((request.cwd as NSString).lastPathComponent)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if request.isDangerous {
                DangerBanner(reasons: request.dangerReasons)
            }

            Text(request.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }

            if let preview = request.preview {
                PreviewBlock(preview: preview)
            }

            // No Spacer here — let the buttons sit directly under the
            // content. The window sizing in size(for:) is calibrated to
            // match content height, so we don't need to push them down.
            HStack(spacing: 8) {
                NotchButton(label: "Deny", style: .destructive, shortcut: "⎋") {
                    onResolve(.deny, .none)
                }
                if let onDenyReason {
                    Button(action: onDenyReason) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Deny with a reason — tell Claude what to do instead")
                }
                if !request.isDangerous {
                    Menu {
                        Button("Always Allow This Exact Command") {
                            onResolve(.allow, .exactCommand)
                        }
                        Button("Always Allow All \(request.toolName)") {
                            onResolve(.allow, .tool)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Always Allow…")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .opacity(0.7)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.14))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Spacer()
                if request.isDangerous {
                    if useTouchID {
                        // Biometric confirm for destructive commands. The system
                        // sheet appears; only a successful auth allows it.
                        Button {
                            BiometricAuth.confirm(reason: "allow this command: \(String(request.detail.prefix(80)))") { ok in
                                if ok { onResolve(.allow, .none) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: BiometricAuth.iconName)
                                Text("Confirm to Allow")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule(style: .continuous).fill(Color.red.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Confirm with \(BiometricAuth.label) to run this destructive command")
                    } else {
                        HoldToConfirmButton(label: "Hold to Allow", duration: 0.9) {
                            onResolve(.allow, .none)
                        }
                    }
                } else if pendingCount > 1, let onResolveAll {
                    // Multiple permissions queued (e.g. several edits at once)
                    // — one tap approves them all.
                    NotchButton(label: "Allow", style: .secondary) {
                        onResolve(.allow, .none)
                    }
                    NotchButton(label: "Allow All (\(pendingCount))", style: .primary, shortcut: "⏎") {
                        onResolveAll(.allow)
                    }
                } else {
                    NotchButton(label: "Allow", style: .primary, shortcut: "⏎") {
                        onResolve(.allow, .none)
                    }
                }
            }
            .padding(.top, 18)
        }
        .onAppear {
            // Auto-arm the biometric prompt for a dangerous command so you can
            // just touch the sensor — no need to click "Confirm to Allow" first.
            // Small delay lets the card finish animating in. Fires once; the
            // button remains for retry if you cancel the system sheet.
            guard useTouchID, request.isDangerous, !didArmTouchID else { return }
            didArmTouchID = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                BiometricAuth.confirm(reason: "allow this command: \(String(request.detail.prefix(80)))") { ok in
                    if ok { onResolve(.allow, .none) }
                }
            }
        }
    }
}

// MARK: - Danger banner

private struct DangerBanner: View {
    let reasons: [String]
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 11, weight: .bold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("This command is destructive")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red.opacity(0.95))
                ForEach(reasons, id: \.self) { reason in
                    Text("• " + reason)
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Tool preview block

private struct PreviewBlock: View {
    let preview: ToolPreview

    var body: some View {
        switch preview {
        case .diff(let hunk):
            DiffPreviewView(hunk: hunk)
        case .multiDiff(let count, let hunk):
            VStack(alignment: .leading, spacing: 4) {
                Text("First of \(count) edits")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .textCase(.uppercase)
                DiffPreviewView(hunk: hunk)
            }
        case .write(let head, let total):
            WritePreviewView(head: head, totalLines: total)
        }
    }
}

private struct DiffPreviewView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { _, line in
                lineView("−", line, fg: .red.opacity(0.9), bg: .red.opacity(0.18))
            }
            if hunk.truncatedOld {
                ellipsisLine(fg: .red.opacity(0.6))
            }
            ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { _, line in
                lineView("+", line, fg: .green.opacity(0.95), bg: .green.opacity(0.18))
            }
            if hunk.truncatedNew {
                ellipsisLine(fg: .green.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func lineView(_ marker: String, _ line: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 6) {
            Text(marker)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(fg.opacity(0.75))
                .frame(width: 10, alignment: .center)
            Text(line.isEmpty ? " " : line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }

    private func ellipsisLine(fg: Color) -> some View {
        HStack {
            Text("⋯")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(fg)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity)
        .background(fg.opacity(0.08))
    }
}

private struct WritePreviewView: View {
    let head: String
    let totalLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(head)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12))
            if totalLines > ToolPreviewParser.maxWriteLines {
                Text("…and \(totalLines - ToolPreviewParser.maxWriteLines) more line\(totalLines - ToolPreviewParser.maxWriteLines == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Hold-to-confirm button

private struct HoldToConfirmButton: View {
    let label: String
    let duration: Double
    let onConfirm: () -> Void

    @State private var pressing = false
    @State private var progress: Double = 0

    var body: some View {
        Text(pressing ? "Hold…" : label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minWidth: 110, minHeight: 26)
            .background(
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(Color.red.opacity(0.45))
                        Capsule(style: .continuous)
                            .fill(Color.red)
                            .frame(width: geo.size.width * progress)
                    }
                }
            )
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startPress() }
                    .onEnded { _ in endPress() }
            )
            .help("Press and hold to confirm — this command was flagged as destructive")
    }

    private func startPress() {
        guard !pressing else { return }
        pressing = true
        withAnimation(.linear(duration: duration)) { progress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if pressing {
                pressing = false
                onConfirm()
                // Instant reset — onConfirm dismisses the card anyway,
                // but make sure progress doesn't linger if the card stays.
                progress = 0
            }
        }
    }

    private func endPress() {
        guard pressing else { return }
        pressing = false
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
}

// MARK: - History drawer

private struct HistoryCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.white.opacity(0.85))
                    .font(.system(size: 13, weight: .semibold))
                Text("Activity")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .textCase(.uppercase)
                Text("·").foregroundColor(.white.opacity(0.3))
                Text("\(state.history.count) event\(state.history.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Button("Clear") { state.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            if state.history.isEmpty {
                Text("Nothing yet — permissions and questions you resolve will show up here.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(state.history) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            HStack {
                Spacer()
                NotchButton(label: "Close", style: .primary, shortcut: "⏎") {
                    state.closeHistory()
                }
            }
            .padding(.top, 18)
        }
    }
}

private struct HistoryRow: View {
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

// MARK: - Notification (non-blocking)

private struct NotificationCard: View {
    let request: PermissionRequest
    let onOpen: () -> Void
    let onDismiss: () -> Void
    private let rowSpacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text(request.source)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.orange.opacity(0.9))
                        .textCase(.uppercase)
                    Text("·").foregroundColor(.white.opacity(0.3))
                    Text(timeAgo(request.receivedAt))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)

                    if !request.detail.isEmpty {
                        Text(request.detail)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    NotchButton(label: "Dismiss", style: .secondary, action: onDismiss)
                    NotchButton(label: "Open IDE", style: .primary, action: onOpen)
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - Completed

private struct CompletedCard: View {
    let task: CompletedTask
    var onReply: (() -> Void)? = nil
    let onOpen: () -> Void
    let onDismiss: () -> Void
    private let rowSpacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Text(task.source)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.green.opacity(0.9))
                        .textCase(.uppercase)
                    Text("·").foregroundColor(.white.opacity(0.3))
                    Text(timeAgo(task.receivedAt))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)

                    if !task.detail.isEmpty {
                        Text(task.detail)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if let onReply {
                        NotchButton(label: "Reply", style: .secondary, action: onReply)
                    }
                    NotchButton(label: "Open IDE", style: .secondary, action: onOpen)
                    NotchButton(label: "Done", style: .primary, action: onDismiss)
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - Auto-approved (info only, no buttons)

private struct AutoInfoCard: View {
    let request: PermissionRequest
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.checkmark.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .semibold))
                Text("Auto-allowed")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.green.opacity(0.9))
                    .textCase(.uppercase)
                Text("·").foregroundColor(.white.opacity(0.3))
                Text(request.toolName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Text("click to dismiss")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.3))
            }
            Text(request.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }
}

// MARK: - Button

private struct NotchButton: View {
    enum Style { case primary, secondary, destructive }
    let label: String
    let style: Style
    var shortcut: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(textColor.opacity(0.55))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var textColor: Color {
        switch style {
        case .primary:     return .black
        case .secondary:   return .white.opacity(0.85)
        case .destructive: return Color.red.opacity(0.95)
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            return hovering ? .white : Color.white.opacity(0.94)
        case .secondary:
            return hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.1)
        case .destructive:
            return hovering ? Color.red.opacity(0.22) : Color.red.opacity(0.13)
        }
    }
}

// MARK: - Question

private struct QuestionCard: View {
    let request: QuestionRequest
    let onSubmit: ([[String]]) -> Void
    let onCancel: () -> Void

    // selections[questionIndex] = set of selected option labels
    @State private var selections: [Set<String>] = []
    // others[questionIndex] = free-text "type your own" answer (optional)
    @State private var others: [String] = []
    @FocusState private var focusedOther: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(.purple)
                    .font(.system(size: 14, weight: .semibold))
                Text(request.source)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.purple.opacity(0.9))
                    .textCase(.uppercase)
                Text("·").foregroundColor(.white.opacity(0.3))
                Text("\(request.questions.count) question\(request.questions.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
            }

            // Let the option list fill whatever vertical space the window
            // gives us — the panel size in NotchView.size() already accounts
            // for every option, so a ScrollView only kicks in on extreme
            // counts that exceed the screen-height cap.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(request.questions.enumerated()), id: \.element.id) { (idx, q) in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                if !q.header.isEmpty {
                                    Text(q.header)
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundColor(.purple.opacity(0.85))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.purple.opacity(0.18))
                                        )
                                }
                                Text(q.text)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                            }
                            ForEach(q.options) { opt in
                                optionRow(qIdx: idx, q: q, opt: opt)
                            }
                            otherRow(qIdx: idx, q: q)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                NotchButton(label: "Cancel", style: .secondary, action: onCancel)
                NotchButton(label: "Send", style: .primary) {
                    onSubmit(buildAnswers())
                }
            }
            .padding(.top, 18)
        }
        .onAppear {
            if selections.count != request.questions.count {
                selections = Array(repeating: Set<String>(), count: request.questions.count)
            }
            if others.count != request.questions.count {
                others = Array(repeating: "", count: request.questions.count)
            }
        }
    }

    /// Combine the picked options with any typed "Other" text. For
    /// single-select a typed answer replaces the radio pick; for multi-select
    /// it's added alongside.
    private func buildAnswers() -> [[String]] {
        request.questions.enumerated().map { (idx, q) in
            let custom = (others.indices.contains(idx) ? others[idx] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var picks = selections.indices.contains(idx) ? Array(selections[idx]).sorted() : []
            if !custom.isEmpty {
                if q.multiSelect { picks.append(custom) } else { picks = [custom] }
            }
            return picks
        }
    }

    @ViewBuilder
    private func otherRow(qIdx: Int, q: AskQuestion) -> some View {
        let active = !(others.indices.contains(qIdx) ? others[qIdx] : "")
            .trimmingCharacters(in: .whitespaces).isEmpty
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: active ? "pencil.circle.fill" : "pencil.circle")
                .foregroundColor(active ? .purple : .white.opacity(0.4))
                .font(.system(size: 13))
                .frame(width: 16)
            TextField("Something else… (type your own answer)", text: Binding(
                get: { others.indices.contains(qIdx) ? others[qIdx] : "" },
                set: { if others.indices.contains(qIdx) { others[qIdx] = $0 } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .focused($focusedOther, equals: qIdx)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.purple.opacity(0.18) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(focusedOther == qIdx ? Color.purple.opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func optionRow(qIdx: Int, q: AskQuestion, opt: AskOption) -> some View {
        let isSelected = (selections.indices.contains(qIdx) && selections[qIdx].contains(opt.label))
        Button(action: { toggle(qIdx: qIdx, multi: q.multiSelect, label: opt.label) }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected
                      ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (q.multiSelect ? "square" : "circle"))
                    .foregroundColor(isSelected ? .purple : .white.opacity(0.4))
                    .font(.system(size: 13))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(opt.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    if !opt.description.isEmpty {
                        Text(opt.description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.purple.opacity(0.18) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private func toggle(qIdx: Int, multi: Bool, label: String) {
        guard selections.indices.contains(qIdx) else { return }
        if multi {
            if selections[qIdx].contains(label) { selections[qIdx].remove(label) }
            else { selections[qIdx].insert(label) }
        } else {
            selections[qIdx] = [label]
        }
    }
}

// MARK: - Markdown rendering

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(index: Int, String)
    case code(language: String?, content: String)
    case blank
}

func parseMarkdownBlocks(_ src: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var inCode = false
    var codeLang: String? = nil

    func flushParagraph() {
        guard !paragraphLines.isEmpty else { return }
        let combined = paragraphLines.joined(separator: " ")
        if !combined.trimmingCharacters(in: .whitespaces).isEmpty {
            blocks.append(.paragraph(combined))
        }
        paragraphLines.removeAll()
    }

    for rawLine in src.components(separatedBy: "\n") {
        let line = rawLine

        // Fenced code blocks
        if line.hasPrefix("```") {
            if inCode {
                blocks.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                inCode = false
                codeLang = nil
            } else {
                flushParagraph()
                inCode = true
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLang = lang.isEmpty ? nil : lang
            }
            continue
        }
        if inCode {
            codeLines.append(line)
            continue
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flushParagraph()
            blocks.append(.blank)
            continue
        }

        // Headings (#, ##, ###)
        if trimmed.hasPrefix("# ") {
            flushParagraph()
            blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
            continue
        }
        if trimmed.hasPrefix("## ") {
            flushParagraph()
            blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
            continue
        }
        if trimmed.hasPrefix("### ") {
            flushParagraph()
            blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
            continue
        }

        // Bullet lists
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            flushParagraph()
            blocks.append(.bullet(String(trimmed.dropFirst(2))))
            continue
        }

        // Numbered lists (e.g. "1. text")
        if let dot = trimmed.firstIndex(of: "."),
           let n = Int(trimmed[..<dot]),
           trimmed.distance(from: trimmed.startIndex, to: dot) <= 3,
           trimmed.index(after: dot) < trimmed.endIndex,
           trimmed[trimmed.index(after: dot)] == " " {
            flushParagraph()
            let rest = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
            blocks.append(.numbered(index: n, rest))
            continue
        }

        paragraphLines.append(trimmed)
    }
    flushParagraph()
    if !codeLines.isEmpty {
        blocks.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
    }
    return blocks
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            attributed(text)
                .font(.system(size: headingSize(level), weight: .bold, design: .default))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 6 : 2)

        case .paragraph(let text):
            attributed(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 10, alignment: .center)
                attributed(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .numbered(let idx, let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\(idx).")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 18, alignment: .trailing)
                attributed(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .code(let lang, let content):
            VStack(alignment: .leading, spacing: 4) {
                if let lang, !lang.isEmpty {
                    Text(lang)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                        .textCase(.uppercase)
                }
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

        case .blank:
            Spacer().frame(height: 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 16
        case 2: return 14
        default: return 13
        }
    }

    private func attributed(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

private func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    let m = s / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    return "\(h)h ago"
}
