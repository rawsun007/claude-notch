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

struct NotchView: View {
    @ObservedObject var state: AppState
    @State private var compactHeight: CGFloat = 0

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
                return CGSize(width: 500, height: inset + 110)
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
            return CGSize(width: 500, height: inset + 116)
        case .question(let q):
            // Header strip ≈ 30, button row ≈ 44, outer padding/spacing ≈ 30.
            // Each question heading ≈ 26 + 6 spacing; each option row ≈ 48
            // (icon + 12pt label + 10pt description + 5pt vertical padding ×2).
            let perOption: CGFloat = 48
            let perQuestion: CGFloat = 26 + 6 + CGFloat(q.questions.first?.options.count ?? 1) * perOption
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

    // boring.notch-style springs: gentle, slightly-bouncy open; fully
    // damped (no bounce) close so it never snaps shut.
    static let openSpring  = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let closeSpring = Animation.spring(response: 0.40, dampingFraction: 1.0)
    static let hoverSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)

    var body: some View {
        // The PANEL is a fixed large window. We draw the notch card pinned to
        // its top and animate the card's SIZE with SwiftUI springs — the
        // window itself never resizes, which is what makes the motion smooth
        // (no AppKit frame animation fighting SwiftUI) and kills the
        // "pops twice" double-relayout entirely.
        let card = NotchView.size(for: state.mode, hovering: state.isHovering, on: NSScreen.main)
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
        return ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if !collapsed {
                    content
                        .frame(maxWidth: .infinity, maxHeight: isScrollableMode ? .infinity : nil, alignment: .top)
                        .padding(.horizontal, 22)
                        .padding(.top, state.notchTopInset + 10)
                        .padding(.bottom, 18)
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
            // Black fill + clip apply AT the (animating) explicit frame size,
            // so the shape grows from the notch out to the card.
            .frame(width: card.width, height: displayHeight, alignment: .top)
            .background(Color.black)
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(collapsed ? 0 : 0.05), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentHeightKey.self) { h in
            compactHeight = h
        }
        // Reset the measured height the instant the mode changes so the card
        // doesn't briefly inherit the PREVIOUS card's height (which made the
        // open jump instead of animate). It falls back to the formula height
        // for one frame, then the GeometryReader refines to the exact height.
        .onChange(of: state.mode) { _ in compactHeight = 0 }
        // Animate on the geometry itself, so BOTH open and close spring
        // symmetrically no matter what changed the size (mode OR measurement).
        .animation(Self.openSpring, value: displayHeight)
        .animation(Self.openSpring, value: card.width)
        .animation(Self.hoverSpring, value: state.isHovering)
    }

    private var isCollapsedIdle: Bool {
        if case .idle = state.mode, !state.isHovering { return true }
        return false
    }

    /// Modes that wrap a ScrollView and need a bounded (fixed) height so the
    /// scroll region doesn't run unbounded behind the notch.
    private var isScrollableMode: Bool {
        switch state.mode {
        case .history, .responseDetail: return true
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
                PermissionCard(request: req) { decision, scope in
                    state.resolveCurrentPermission(decision, alwaysAllow: scope)
                }
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
            CompletedCard(task: task, onOpen: {
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
        }
    }

    /// Concave top-corner radius — the "ears" that blend the card into the
    /// menu bar / physical notch. Small when closed (≈ the real notch), a
    /// touch larger when open.
    private var notchTopRadius: CGFloat {
        isCollapsedIdle ? 9 : 12
    }

    /// Convex bottom-corner radius — grows with the card so big cards have a
    /// softer hang.
    private var notchBottomRadius: CGFloat {
        if isCollapsedIdle { return 11 }
        switch state.mode {
        case .responseDetail, .history: return 30
        default:                        return 26
        }
    }

}

// MARK: - shared spec for IdlePill content

extension NotchView {
    fileprivate func idleSubtitle() -> String {
        // Most-recently updated signal wins. If both are recent, prefer
        // the actual response over the tool call.
        let r = state.lastClaudeResponseAt ?? .distantPast
        let a = state.lastActivityAt ?? .distantPast
        if r >= a && !state.lastClaudeResponse.isEmpty { return state.lastClaudeResponse }
        if !state.lastActivity.isEmpty { return state.lastActivity }
        if !state.lastUserPrompt.isEmpty { return state.lastUserPrompt }
        return "ready"
    }
}


// MARK: - Idle

private struct IdlePill: View {
    @ObservedObject var state: AppState

    private var subtitle: String {
        let r = state.lastClaudeResponseAt ?? .distantPast
        let a = state.lastActivityAt ?? .distantPast
        if r >= a && !state.lastClaudeResponse.isEmpty { return state.lastClaudeResponse }
        if !state.lastActivity.isEmpty   { return state.lastActivity }
        if !state.lastUserPrompt.isEmpty { return state.lastUserPrompt }
        return "ready"
    }

    private var dotColor: Color {
        if !state.lastClaudeResponse.isEmpty { return Color.green }
        if !state.lastActivity.isEmpty       { return Color.blue }
        return Color.gray
    }

    private var canExpand: Bool { !state.fullClaudeResponse.isEmpty }
    private var canShowHistory: Bool { !state.history.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.currentProject.isEmpty ? "ClaudeNotch" : state.currentProject)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Body tap → history drawer when we have anything to show.
                // Falls through to the response detail when only that's available.
                if canShowHistory { state.openHistory() }
                else if canExpand { state.showResponseDetail() }
            }
            Spacer(minLength: 0)
            if canShowHistory {
                Button {
                    state.openHistory()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Show history")
            }
            if canExpand {
                Button {
                    state.showResponseDetail()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Expand response")
            }
        }
    }
}

// MARK: - Compose

private struct ComposeCard: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    private var targetLabel: String {
        guard let bid = state.composeTarget else { return "no terminal found" }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           let name = app.localizedName { return name }
        return bid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.cyan)
                    .font(.system(size: 13, weight: .semibold))
                Text("Send to Claude")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.cyan.opacity(0.9))
                    .textCase(.uppercase)
                Text("·").foregroundColor(.white.opacity(0.3))
                Text("→ \(targetLabel)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()
            }

            ZStack(alignment: .topLeading) {
                if state.composeText.isEmpty {
                    Text("type your message — ⌘↩ to send, ↩ for newline, ⎋ to cancel")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $state.composeText)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
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
                NotchButton(label: "Cancel", style: .secondary, shortcut: "⎋") {
                    state.cancelCompose()
                }
                NotchButton(label: "Send", style: .primary, shortcut: "⌘↩") {
                    state.sendCompose()
                }
            }
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
                if !state.currentProject.isEmpty {
                    Text("·").foregroundColor(.white.opacity(0.3))
                    Text(state.currentProject)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parseMarkdownBlocks(state.fullClaudeResponse).enumerated()), id: \.offset) { _, block in
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
    let onResolve: (PermissionDecision, AllowScope) -> Void

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
                    HoldToConfirmButton(label: "Hold to Allow", duration: 0.9) {
                        onResolve(.allow, .none)
                    }
                } else {
                    NotchButton(label: "Allow", style: .primary, shortcut: "⏎") {
                        onResolve(.allow, .none)
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13, weight: .semibold))
                Text(request.source)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.orange.opacity(0.9))
                    .textCase(.uppercase)
                Spacer()
                Text(timeAgo(request.receivedAt))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }

            Text(request.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)

            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                NotchButton(label: "Dismiss", style: .secondary, action: onDismiss)
                NotchButton(label: "Open IDE", style: .primary, action: onOpen)
            }
        }
    }
}

// MARK: - Completed

private struct CompletedCard: View {
    let task: CompletedTask
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14, weight: .semibold))
                Text(task.source)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.green.opacity(0.9))
                    .textCase(.uppercase)
                Spacer()
                Text(timeAgo(task.receivedAt))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }

            Text(task.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)

            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                NotchButton(label: "Open IDE", style: .secondary, action: onOpen)
                NotchButton(label: "Done", style: .primary, action: onDismiss)
            }
        }
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
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                NotchButton(label: "Cancel", style: .secondary, action: onCancel)
                NotchButton(label: "Send", style: .primary, shortcut: "⏎") {
                    let answers = selections.map { Array($0).sorted() }
                    onSubmit(answers)
                }
            }
        }
        .onAppear {
            if selections.count != request.questions.count {
                selections = Array(repeating: Set<String>(), count: request.questions.count)
            }
        }
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
