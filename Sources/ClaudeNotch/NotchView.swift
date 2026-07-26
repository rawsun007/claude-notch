import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    /// The screen this instance renders on. `nil` = the primary, cursor-following
    /// panel (uses NSScreen.main + the shared, live notchTopInset — unchanged
    /// behavior). Non-nil = a per-screen mirror panel pinned to `screenOverride`,
    /// which must size to ITS OWN screen's notch/pill, not the primary's.
    var screenOverride: NSScreen? = nil
    @State private var compactHeight: CGFloat = 0
    @StateObject private var sizer = CardSizeAnimator()

    /// The screen to measure geometry against for this panel.
    private var localScreen: NSScreen? { screenOverride ?? NSScreen.main }
    /// Top inset for this panel. For the primary it's the shared live value
    /// (identical to before); for a mirror it's computed from its own screen.
    private var localInset: CGFloat {
        screenOverride != nil ? NotchView.notchInset(on: screenOverride) : state.notchTopInset
    }

    /// Horizontal breathing room between the card content and the notch's
    /// left/right edges. Tuned together with the bottom corner radius (~18 pt)
    /// so the bottom button row clears the curve. One knob for all cards.
    private let contentHorizontalPadding: CGFloat = 28

    /// Dev switch to force the non-notch (Dynamic-Island pill) rendering on a
    /// notched Mac, so the layout can be developed and screenshot-verified
    /// without external hardware. Set CLAUDENOTCH_FAKE_NOTCH=1 in the env.
    static let forceFakeNotch = ProcessInfo.processInfo.environment["CLAUDENOTCH_FAKE_NOTCH"] == "1"

    /// Whether `screen` has a real hardware notch we should merge into. On Macs
    /// without one (Air, older MacBooks, and every external display) we instead
    /// draw a floating Dynamic-Island-style pill.
    static func hasNotch(_ screen: NSScreen?) -> Bool {
        if forceFakeNotch { return false }
        guard let screen else { return false }
        return screen.safeAreaInsets.top > 0
            && screen.auxiliaryTopLeftArea != nil
            && screen.auxiliaryTopRightArea != nil
    }

    /// Height of the menu bar on `screen` (0 when this display shows no menu
    /// bar, e.g. a secondary display without separate Spaces). Used to place the
    /// non-notch pill just under the bar and keep expanded cards clear of it.
    static func menuBarHeight(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return 24 }
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 1 ? h : 24
    }

    /// How much vertical space the card must leave clear at the top: the physical
    /// notch on a notched Mac, else the menu bar (so the non-notch pill and every
    /// expanded card hang below the bar instead of colliding with it).
    static func notchInset(on screen: NSScreen?) -> CGFloat {
        if hasNotch(screen) { return screen!.safeAreaInsets.top }
        return menuBarHeight(on: screen)
    }

    /// Colour of the PR badge: the review state is the only thing about a PR you
    /// want to know without opening it.
    static func prTint(_ state: String) -> Color {
        switch state {
        case "approved":          return .green.opacity(0.8)
        case "changes_requested": return .orange.opacity(0.85)
        case "draft":             return .white.opacity(0.35)
        default:                  return .white.opacity(0.5)   // pending / unknown
        }
    }

    static func prTooltip(number: Int, state: String) -> String {
        let described: String = {
            switch state {
            case "approved":          return "approved"
            case "changes_requested": return "changes requested"
            case "draft":             return "draft"
            case "pending":           return "review pending"
            default:                  return ""
            }
        }()
        let base = "Pull request #\(number)"
        return described.isEmpty ? base : "\(base) · \(described)"
    }

    /// Shorten a label from the middle, keeping both ends readable
    /// ("feature/really-long-name" → "feature/…-name").
    ///
    /// Done here rather than by SwiftUI's own truncation because a `Text` given a
    /// flexible width will keep shrinking as far as the layout demands — a branch
    /// called "main" was ending up drawn as "m". A label is worth showing when it
    /// can still be read; the eliding stops well before that point, and the full
    /// value stays in the tooltip.
    static func elide(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 3 else { return text }
        let keep = limit - 1                      // room for the ellipsis
        let head = keep - keep / 2
        let tail = keep / 2
        return text.prefix(head) + "…" + text.suffix(tail)
    }

    /// Rendered width of a string in the given font — used to size the idle
    /// card to what it's actually showing instead of a fixed width. A fixed
    /// width either left a big dead gap for a sparse session (no model/
    /// branch/cost yet) or truncated a busy one.
    private static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: size) ?? font
        }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Estimated natural width of the idle card's row 1 + row 2 content.
    /// Mirrors the fields actually rendered in `IdlePill.body` — keep in
    /// sync if that layout changes.
    private static func idleContentWidth(for state: AppState, hovering: Bool) -> CGFloat {
        let spacing: CGFloat = 6
        var row1: [CGFloat] = [15]   // Claude icon
        row1.append(textWidth(state.entityName, size: 12, weight: .semibold))
        row1.append(5)   // status dot
        let statusText = state.claudeActionStatus == "thinking" ? "Thinking"
            : state.isClaudeWorking ? "Running command" : "Ready"
        row1.append(textWidth(statusText, size: 10))
        if let badge = permissionModeBadge(state.currentPermissionMode) {
            row1.append(textWidth(badge.label, size: 9, weight: .semibold) + 10)
        }
        if hovering {
            let agentCount = state.totalRunningAgentCount
            if agentCount > 0 {
                row1.append(textWidth(agentCount == 1 ? "1 agent" : "\(agentCount) agents", size: 9, weight: .medium) + 10)
            }
            let fileCount = state.currentTouchedFiles.count
            if fileCount > 0 {
                row1.append(textWidth(fileCount == 1 ? "1 file" : "\(fileCount) files", size: 9, weight: .medium) + 10)
            }
        }
        row1.append(34)   // trailing history/expand icon buttons
        let row1Width = row1.reduce(0, +) + CGFloat(row1.count - 1) * spacing

        // Row 2 must be measured against what actually renders: the PRIMARY
        // session (not the global mirrors) and the token label (e.g. "939k/1M"),
        // not the tiny percent. Measuring the wrong thing under-sized the card
        // and clipped the content.
        let top = state.primarySession
        let topModel = top?.model ?? state.currentModel
        let isClaudeTop = AgentKind.infer(fromModel: topModel) == .claude
        let (modelName, modelVer) = ClaudeUsageReader.modelNameVersion(topModel)
        let effort = isClaudeTop ? state.currentEffort : ""
        let branch = top?.gitBranch ?? state.currentGitBranch
        let tokens = top?.contextTokens ?? state.currentContextTokens
        let window = top?.contextWindow ?? state.currentContextWindow
        let cost = top?.displayCostUSD ?? state.currentCostUSD
        var row2: [CGFloat] = []
        if !modelName.isEmpty {
            row2.append(textWidth(modelName, size: 10, weight: .semibold))
            if hovering {
                if !modelVer.isEmpty { row2.append(textWidth(modelVer, size: 10)) }
                if !effort.isEmpty { row2.append(2.5) }
            }
        }
        if hovering {
            if !effort.isEmpty { row2.append(textWidth("\(effort) effort", size: 10)) }
            if !branch.isEmpty { row2.append(11 + textWidth(NotchView.elide(branch, to: 12), size: 10)) }
        }
        var bar: [CGFloat] = [36]   // context capsule
        if tokens > 0 {
            bar.append(textWidth("\(fmtK(tokens))/\(fmtK(window > 0 ? window : tokens))", size: 9))
        } else {
            bar.append(textWidth("\(Int((state.currentContextPercent * 100).rounded()))%", size: 9))
        }
        if cost > 0 { bar.append(textWidth(ClaudeUsageReader.fmtMoney(cost), size: 9)) }
        row2.append(bar.reduce(0, +) + CGFloat(bar.count - 1) * 5)
        let row2Width = row2.reduce(0, +) + CGFloat(max(0, row2.count - 1)) * 5

        // Secondary session rows can be wider than the header. Estimate each.
        var maxRow = max(row1Width, row2Width)
        for s in state.activeSessions where s.id != top?.id {
            var r: [CGFloat] = [6]   // status dot
            if AgentKind.infer(fromModel: s.model) != .claude { r.append(44) }   // agent chip
            r.append(textWidth(s.project.isEmpty ? "session" : s.project, size: 11, weight: .medium))
            if !s.gitBranch.isEmpty { r.append(11 + textWidth(NotchView.elide(s.gitBranch, to: 12), size: 10)) }
            r.append(textWidth(s.status.isEmpty ? "ready" : s.status, size: 10) + 12)
            r.append(36)   // its context capsule
            if s.contextTokens > 0 {
                r.append(textWidth("\(fmtK(s.contextTokens))/\(fmtK(s.contextWindow > 0 ? s.contextWindow : s.contextTokens))", size: 9))
            }
            if s.displayCostUSD > 0 { r.append(textWidth(ClaudeUsageReader.fmtMoney(s.displayCostUSD), size: 9)) }
            maxRow = max(maxRow, r.reduce(0, +) + CGFloat(r.count - 1) * spacing)
        }
        return maxRow
    }

    /// Compact token count for width estimates (mirrors ContextCostBar.fmtK).
    private static func fmtK(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        return n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }


    static func size(for mode: NotchMode, hovering: Bool = false, on screen: NSScreen? = nil, state: AppState? = nil) -> CGSize {
        let s = screen ?? NSScreen.main
        let inset = notchInset(on: s)
        // Rule of thumb: visible-height must be >= 2 * cornerRadius so the bottom
        // arc has straight side wall above it to flow out of (otherwise the
        // curve dominates the whole visible area and looks like a wedge).
        switch mode {
        case .idle:
            let base = collapsedSize(on: s)
            // A file is being dragged over the notch: grow it into a clear
            // drop target with room for the "Open in Claude" hint. Checked
            // first so it wins even when the card is being held open.
            if state?.isDropTarget == true || state?.isDropHot == true {
                return CGSize(width: max(base.width, 260), height: inset + 70)
            }
            // The card is "open" — and shows the full meter + detail — whenever
            // the cursor is on the notch OR persistentNotchDisplay is holding it
            // open. Both states get the same size so they show the same data.
            let full = hovering || (state?.persistentNotchDisplay == true)
            guard full else {
                // Pet mode: the card grows just enough to be the stage for
                // whatever the pet is currently doing. It's not "opening" —
                // the notch swells a little and the mascot moves in it.
                guard let activity = state?.petActivity, activity != .tucked else { return base }
                return CGSize(width: base.width + activity.stageWidthPad,
                              height: inset + activity.stageDrop)
            }
            // 28pt horizontal padding each side (contentHorizontalPadding),
            // clamped so a sparse session doesn't get the old fixed 380 of
            // mostly empty space, and a busy one still gets enough room.
            guard let state else { return CGSize(width: 380, height: inset + 64) }
            // +12 slack on top of the 56pt content padding — NSFont measuring
            // and SwiftUI's actual Text layout don't agree to the pixel, and
            // running short here is what truncates the model name.
            // Cap raised to 404 so a busy row (model + effort + branch + meter +
            // cost) has room instead of overflowing the card on a long branch.
            // Cap raised to 520: a two-agent card (model + effort + branch +
            // token label + cost, plus a secondary session row) needs the room,
            // and under-sizing clipped the content on both edges.
            let width = min(520, max(230, idleContentWidth(for: state, hovering: true) + 56 + 12))
            return CGSize(width: width, height: inset + 64)
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
            if req.budgetBlock != nil {
                visible += 46   // two-line orange banner + gap
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
            // Each question heading ≈ 26 + 6 spacing; each option row is a 12pt
            // label plus a description that now WRAPS instead of clipping, so it
            // is budgeted for roughly two lines of description rather than one.
            // Underestimating only means the scroll kicks in sooner; it never
            // hides text.
            let perOption: CGFloat = 66
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
            // Tall drawer (search + filters + scroll-back log); cap at 72% of
            // screen on small displays.
            let screenH = s?.frame.height ?? 900
            return CGSize(width: 640, height: min(inset + 520, screenH * 0.72))
        case .autoInfo:
            // Compact, button-less "live activity" card.
            return CGSize(width: 460, height: inset + 96)
        }
    }

    /// On notched MacBooks: match the physical notch so we visually merge.
    /// On non-notched Macs (Air, older): draw a Dynamic-Island-style fake notch
    /// of similar dimensions, hanging from the top.
    static func collapsedSize(on screen: NSScreen?) -> CGSize {
        if hasNotch(screen), let screen,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = max(160, right.minX - left.maxX)
            let height = max(28, screen.safeAreaInsets.top)
            return CGSize(width: width, height: height)
        }
        // No physical notch — a floating pill sized to sit within the menu-bar
        // band (its height matches notchInset so the pill and the inset agree).
        return CGSize(width: 200, height: max(28, menuBarHeight(on: screen)))
    }

    var body: some View {
        // The PANEL is a fixed large window. We draw the notch card pinned to
        // its top and animate the card's SIZE with SwiftUI springs — the
        // window itself never resizes, which is what makes the motion smooth
        // (no AppKit frame animation fighting SwiftUI) and kills the
        // "pops twice" double-relayout entirely.
        let card = NotchView.size(for: state.mode, hovering: isIdleOpen, on: localScreen, state: state)
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

        // Rope is special: the black notch card must NOT grow, so it reads as
        // the rope and pet coming out of the *real* hardware notch rather than
        // out of a card that unfurled. The pet draws BEHIND a collapsed black
        // notch (its top hidden by it, exactly like the hardware notch would),
        // and its body hangs below on the transparent panel.
        if isPetOut, PetEngine.isHanging(state.petActivity) {
            // The black notch must match the HARDWARE cutout exactly, not the
            // (wider) pet stage — otherwise it grows black wings out past the
            // real notch and the whole illusion breaks. The pet stage is wider
            // so the pet has room to swing; only the black is clamped.
            let notch = NotchView.collapsedSize(on: localScreen)
            return AnyView(
                ZStack(alignment: .top) {
                    PetStageView(state: state, stageWidth: card.width, notchInset: localInset)
                        .frame(width: card.width, height: card.height, alignment: .top)
                    // The collapsed black notch, on top, covering the pet's top,
                    // so the swing reads as the pet hanging out of the real notch.
                    Color.black
                        .frame(width: notch.width, height: notch.height)
                        .clipShape(shape)
                        .contentShape(Rectangle())
                        .onTapGesture { state.petBoop() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            )
        }

        return AnyView(ZStack(alignment: .top) {
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
                        .padding(.top, localInset + 10)
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
                } else if isPetOut && !state.isDropTarget && !state.isDropHot {
                    // The mascot living its own life on the notch's lip.
                    PetStageView(state: state, stageWidth: card.width, notchInset: localInset)
                        .frame(width: card.width, height: card.height, alignment: .top)
                } else {
                    // Collapsed idle: nothing but the notch.
                    //
                    // The status row used to live here, and it never fitted: the
                    // collapsed card is exactly as wide as the hardware cutout, so
                    // every figure in it was squeezed down to an ellipsis. A row of
                    // "8…" and "$…" is not information, it is litter, and it was
                    // sitting in the one place the app is supposed to be invisible.
                    // The limits live in the expanded notch now, where they fit and
                    // can show their reset countdowns.
                    //
                    // Clicking the bare notch still wakes the pet — the notch is
                    // where it lives.
                    ZStack {
                        Color.clear
                    }
                    .frame(width: card.width, height: card.height)
                    .contentShape(Rectangle())
                    .onTapGesture { state.petBoop() }
                }
            }
            // Black fill + clip apply AT the animating frame size, so the
            // shape grows from the notch out to the card while the content
            // stays at full size underneath (revealed by the growing clip).
            .frame(width: w, height: h, alignment: .top)
            .background(Color.black)
            // A drag over the notch takes over the WHOLE card: a black panel with
            // the Apple-style drop zone, on top of and masking whatever the card
            // was showing (status, pet, anything). Driven only by the drop flags,
            // so it appears whether or not the card was already open on hover.
            .overlay(alignment: .top) {
                if state.isDropTarget || state.isDropHot {
                    dropZone(width: w, height: h)
                        .transition(.opacity)
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(collapsed ? 0 : 0.05),
                                  lineWidth: 0.5))
            .animation(.easeOut(duration: 0.15), value: state.isDropTarget)
        }
        // Drop a file or folder on the notch to open Claude there. This is a
        // GENEROUS invisible catcher over the notch area, not the tiny visible
        // card — the same trick boring.notch uses. A drag has somewhere real to
        // land, and the drop is caught even though clicks elsewhere pass through.
        .background(
            Color.clear
                // Cover the WHOLE visible card, not a thin strip at the very top.
                // The card expands on hover, and a dragged folder lands on the
                // body of the expanded card (well below the notch lip). A 70pt
                // top strip missed every real drop, so the file fell through to
                // the desktop. Match the animating card size so wherever on the
                // card the folder is dropped, it is caught.
                .frame(width: max(w, 240), height: max(h, localInset + 30))
                .contentShape(Rectangle())
                // ONE drop target for the whole card. A DropDelegate (not a second
                // onDrop) reports the live drag location, so the inner icon box can
                // glow green from geometry — no competing drop views fighting over
                // targeting, which was flickering the panel and eating the drop.
                .onDrop(of: [UTType.fileURL], delegate: NotchDropDelegate(
                    state: state,
                    hotRect: CGRect(
                        x: 14,
                        y: localInset + 8,
                        width: max(max(w, 240) - 28, 0),
                        height: max(max(h, localInset + 30) - (localInset + 8) - 12, 0)
                    )
                )),
            alignment: .top
        )
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
        })
    }

    private var isCollapsedIdle: Bool {
        if case .idle = state.mode, !isIdleOpen { return true }
        return false
    }

    private var isPetOut: Bool {
        if case .idle = state.mode, !isIdleOpen, state.petActivity != .tucked { return true }
        return false
    }

    private var isIdleOpen: Bool {
        state.persistentNotchDisplay || state.isHovering
    }

    /// The Apple-style drop panel: a black fill covering the card with a centred
    /// dashed box and drop-doc glyph. Blue by default; glows green (`isDropHot`)
    /// while the file is right over the box, as a "let go here" cue.
    @ViewBuilder
    private func dropZone(width w: CGFloat, height h: CGFloat) -> some View {
        let hot = state.isDropHot
        let tint = hot ? Color.green : Color(red: 0.29, green: 0.56, blue: 1.0)
        ZStack {
            Color.black
            VStack(spacing: 3) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text(hot ? "Release to open" : "Drop here")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundColor(tint)
            // Space around the glyph so it sits comfortably inside the dashes,
            // not cramped against them.
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(hot ? 0.16 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(hot ? 0.95 : 0.7),
                                          style: StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                    )
            )
            // Even margin on all four sides so the dashed box floats inside the
            // black card with breathing room top, bottom and sides.
            .padding(.horizontal, 14)
            .padding(.top, localInset + 8)
            .padding(.bottom, 12)
            .animation(.easeOut(duration: 0.12), value: hot)
        }
        .frame(width: w, height: h, alignment: .top)
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
                    useTouchID: state.requireTouchID && BiometricAuth.isAvailable,
                    onRaiseCap: { state.raiseBudgetAndAllow() },
                    onDisableEnforce: { state.disableEnforcementAndAllow() },
                    raiseCapTarget: req.budgetBlock.map { state.raisedCapTarget(for: $0) } ?? 0,
                    showPet: state.petEnabled
                )
                // Fresh card per request id so the hold-to-confirm gesture
                // state (pressing / progress) can't carry over to the next one.
                .id(req.id)
                .transition(.opacity)
            } else {
                NotificationCard(request: req, showPet: state.petEnabled, onOpen: {
                    state.openOriginator(req.originatorBundleID)
                    state.resolveCurrentPermission(.ask)
                }, onDismiss: {
                    state.resolveCurrentPermission(.ask)
                })
                .transition(.opacity)
            }
        case .completed(let task):
            CompletedCard(task: task, showPet: state.petEnabled, onReply: {
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
            // Key by request id so a queued question (e.g. from another
            // concurrent session) gets a fresh card: its @State selections /
            // "Other" text are rebuilt instead of leaking from the prior one.
            .id(req.id)
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
