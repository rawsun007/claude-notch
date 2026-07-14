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

        let (modelName, modelVer) = ClaudeUsageReader.modelNameVersion(state.currentModel)
        var row2: [CGFloat] = []
        if !modelName.isEmpty {
            row2.append(textWidth(modelName, size: 10, weight: .semibold))
            if hovering {
                if !modelVer.isEmpty { row2.append(textWidth(modelVer, size: 10)) }
                if !state.currentEffort.isEmpty { row2.append(2.5) }
            }
        }
        if hovering {
            if !state.currentEffort.isEmpty {
                row2.append(textWidth("\(state.currentEffort) effort", size: 10))
            }
            if !state.currentGitBranch.isEmpty {
                row2.append(min(110, 11 + textWidth(state.currentGitBranch, size: 10)))
            }
        }
        var bar: [CGFloat] = [36]   // context capsule
        let percentText = "\(Int((state.currentContextPercent * 100).rounded()))%"
        bar.append(textWidth(percentText, size: 9))
        if state.currentCostUSD > 0 {
            bar.append(textWidth(ClaudeUsageReader.fmtMoney(state.currentCostUSD), size: 9))
        }
        row2.append(bar.reduce(0, +) + CGFloat(bar.count - 1) * 5)
        let row2Width = row2.reduce(0, +) + CGFloat(max(0, row2.count - 1)) * 5

        return max(row1Width, row2Width)
    }


    static func size(for mode: NotchMode, hovering: Bool = false, on screen: NSScreen? = nil, state: AppState? = nil) -> CGSize {
        let s = screen ?? NSScreen.main
        let inset = notchInset(on: s)
        // Rule of thumb: visible-height must be >= 2 * cornerRadius so the bottom
        // arc has straight side wall above it to flow out of (otherwise the
        // curve dominates the whole visible area and looks like a wedge).
        switch mode {
        case .idle:
            guard hovering else {
                let base = collapsedSize(on: s)
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
            let width = min(380, max(230, idleContentWidth(for: state, hovering: true) + 56 + 12))
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
        let card = NotchView.size(for: state.mode, hovering: isIdleOpen, on: NSScreen.main, state: state)
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
        if isPetOut, state.petActivity == .rope {
            // The black notch must match the HARDWARE cutout exactly, not the
            // (wider) pet stage — otherwise it grows black wings out past the
            // real notch and the whole illusion breaks. The pet stage is wider
            // so the pet has room to swing; only the black is clamped.
            let notch = NotchView.collapsedSize(on: NSScreen.main)
            return AnyView(
                ZStack(alignment: .top) {
                    PetStageView(state: state, stageWidth: card.width, notchInset: state.notchTopInset)
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
                } else if isPetOut {
                    // The mascot living its own life on the notch's lip.
                    PetStageView(state: state, stageWidth: card.width, notchInset: state.notchTopInset)
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
                    Color.clear
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
                NotificationCard(request: req, onOpen: {
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


// MARK: - Claude brand icon

/// Bare mascot artwork (the Claude Code CLI's pixel-art crab). Bob/scale
/// animation is layered on by callers — this just draws the sprite, falling
/// back to the plain brand mark if the asset didn't ship for some reason.
private struct PetSprite: View {
    var size: CGFloat
    /// Nil renders the pet standing at rest. Everything animated passes a rig.
    var rig: PetRig = PetRig()

    static let colour = Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255)

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, canvasSize in
            let cell = min(canvasSize.width, canvasSize.height) / PetBody.grid
            func rect(_ p: PetPart, dx: Double = 0, dy: Double = 0) -> CGRect {
                CGRect(x: (p.x + dx) * cell, y: (p.y + dy) * cell,
                       width: p.width * cell, height: p.height * cell)
            }

            // Limbs first, torso last: the body then covers every joint, so a
            // swinging arm or a dangling leg stays attached to it instead of
            // opening a gap where it meets the shoulder or hip.
            for (i, leg) in PetBody.legs.enumerated() {
                let lift = rig.legLift[i] + rig.legTuck[i]
                var part = leg
                part.height = max(0, leg.height - rig.legTuck[i])
                guard part.height > 0.01 else { continue }
                ctx.fill(Path(rect(part, dx: rig.legSwing[i], dy: -lift + rig.legTuck[i])),
                         with: .color(Self.colour))
            }

            // Arms pivot at the shoulder — a cell inside the torso, so no angle
            // can lever their inner corner out into the open.
            func arm(_ p: PetPart, pivotCell: PetPart, angle: Double) {
                let r = rect(p)
                let pivot = CGPoint(x: pivotCell.x * cell, y: (pivotCell.y + pivotCell.height / 2) * cell)
                ctx.drawLayer { layer in
                    layer.translateBy(x: pivot.x, y: pivot.y)
                    layer.rotate(by: .degrees(angle))
                    layer.translateBy(x: -pivot.x, y: -pivot.y)
                    layer.fill(Path(r), with: .color(Self.colour))
                }
            }
            // Mirrored: a positive rig angle raises either arm, so the left one
            // turns the opposite way on screen from the right one.
            arm(PetBody.armLeft, pivotCell: PetBody.shoulderLeft, angle: rig.armLeftAngle)
            arm(PetBody.armRight, pivotCell: PetBody.shoulderRight, angle: -rig.armRightAngle)

            for slab in PetBody.torso {
                ctx.fill(Path(rect(slab)), with: .color(Self.colour))
            }

            // Eyes are painted solid dark, not punched through the body. A hole
            // only reads as an eye when the pet sits on black (the notch card);
            // on the transparent panel — where the rope pet hangs over your
            // desktop — a hole shows the wallpaper instead. Solid eyes read the
            // same everywhere. A blink shrinks the eye from the top, like a lid.
            for eye in [PetBody.eyeLeft, PetBody.eyeRight] {
                let open = max(0, rig.eyeOpen)
                guard open > 0.02 else { continue }
                var lid = eye
                lid.height = eye.height * open
                let dy = eye.height - lid.height
                ctx.fill(Path(rect(lid, dx: rig.eyeShift, dy: dy)),
                         with: .color(Color(red: 0.16, green: 0.09, blue: 0.06)))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Row 1's icon — the same mascot, breathing at whatever tempo its mood calls
/// for, so a glance at the notch tells you what Claude is up to before you've
/// read a word of the status text. `mood` is nil when Pet Mode is off, which
/// leaves a gentle default bob rather than a dead sprite.
private struct ClaudeIconView: View {
    var size: CGFloat = 15
    var mood: PetMood? = nil

    /// Bob period (seconds) and amplitude (points) per mood.
    private var beat: (period: Double, amplitude: Double) {
        switch mood {
        case .working:     return (0.7, 1.6)    // busy, quick
        case .thinking:    return (1.1, 1.2)
        case .celebrating: return (0.45, 2.4)   // bouncing
        case .startled:    return (0.3, 2.0)    // jittery
        case .sleepy:      return (3.2, 0.5)    // barely breathing
        case .curious:     return (1.5, 1.0)
        case .calm, .none: return (1.8, 0.9)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { tl in
            let (period, amplitude) = beat
            let phase = tl.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            // Celebrating hops (always up, never down) instead of bobbing.
            let wave = mood == .celebrating ? -abs(sin(phase * .pi * 2)) : sin(phase * 2 * .pi)
            let clock = tl.date.timeIntervalSinceReferenceDate
            // Even at 15pt the pet blinks, and sleeps with its eyes shut.
            let rig = PetRigging.rig(for: mood == .sleepy ? .sleep : .peek,
                                     progress: 0.5, time: clock)
            PetSprite(size: size, rig: rig)
                .offset(y: wave * amplitude)
        }
    }
}

/// The little glyph beside the pet — asleep, being petted, celebrating.
private struct PetEmoteView: View {
    let emote: PetEmote
    let scale: Double

    private var symbol: String {
        switch emote {
        case .zzz:     return "zzz"
        case .heart:   return "heart.fill"
        case .sparkle: return "sparkles"
        case .bang:    return "exclamationmark"
        case .dots:    return "ellipsis"
        }
    }

    private var tint: Color {
        switch emote {
        case .heart:   return Color(red: 1.0, green: 0.42, blue: 0.55)
        case .sparkle: return Color(red: 1.0, green: 0.80, blue: 0.35)
        default:       return .white.opacity(0.55)
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(tint)
            .scaleEffect(max(0.01, scale))
            .shadow(color: tint.opacity(0.5), radius: 3)
    }
}

/// The stage the pet performs on: the collapsed notch card, grown by however
/// much room the current activity needs. Every frame asks PetEngine for a pose
/// and applies it — no SwiftUI implicit animations anywhere, because the pose
/// *is* the animation and mixing the two would double-interpolate it.
private struct PetStageView: View {
    @ObservedObject var state: AppState
    let stageWidth: CGFloat
    let notchInset: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { tl in
            let activity = state.petActivity
            let stage = PetEngine.Stage(
                notchInset: Double(notchInset),
                halfWidth: Double(stageWidth / 2),
                cursorX: state.petCursorX,
                petting: state.petPetting
            )
            let progress = state.petProgress(at: tl.date)
            let pose = PetEngine.pose(for: activity, progress: progress, stage: stage)
            let clock = tl.date.timeIntervalSinceReferenceDate
            let rig = PetRigging.rig(for: activity, progress: progress, time: clock,
                                     cursorX: state.petCursorX)
            let sprite = CGFloat(activity.spriteSize)
            let anchor: UnitPoint = {
                switch activity.pivot {
                case .feet:   return .bottom
                case .paws:   return .top
                case .centre: return .center
                }
            }()

            ZStack(alignment: .top) {
                Color.clear
                // The rope: drawn behind the pet, from the notch's lip down to
                // where the pet grips it. Its end follows the pet's top along the
                // swing, so the line and the creature stay joined at every angle.
                if activity == .rope {
                    let theta: Double = pose.rotation * .pi / 180
                    // Attach to the pet's HEAD (where the paws grip), not the top
                    // of the sprite box — the artwork leaves three empty rows up
                    // there, and measuring to the box left a gap between the rope
                    // and the creature. Overlap a hair into the head so there's
                    // never a seam.
                    let grip = CGFloat(-PetBody.headTopFraction + 0.04) * sprite
                    let topX = CGFloat(pose.x) - CGFloat(sin(theta)) * grip
                    let topY = CGFloat(pose.y) - CGFloat(cos(theta)) * grip
                    // A rope has a fixed length, so while the pet is still falling
                    // the spare rope has to go somewhere: it sags. Straight line
                    // only once the fall has paid the slack out and the rope is
                    // taut. Without this the rope visibly grows out of the notch
                    // like a tape measure.
                    let restLen = CGFloat(PetEngine.ropeRestRadius(activity)) - grip
                    let span = (topX * topX + (topY - CGFloat(notchInset)) * (topY - CGFloat(notchInset))).squareRoot()
                    let slack = max(0, restLen - span)
                    Canvas { ctx, canvasSize in
                        let top = CGPoint(x: canvasSize.width / 2, y: notchInset)
                        let end = CGPoint(x: canvasSize.width / 2 + topX, y: topY)
                        var path = Path()
                        path.move(to: top)
                        if slack > 0.5 {
                            // Hangs its slack below the chord, like a real line.
                            let mid = CGPoint(x: (top.x + end.x) / 2,
                                              y: (top.y + end.y) / 2 + slack * 1.1)
                            path.addQuadCurve(to: end, control: mid)
                        } else {
                            path.addLine(to: end)
                        }
                        ctx.stroke(path, with: .color(Color(white: 0.32).opacity(pose.opacity)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                PetSprite(size: sprite, rig: rig)
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
                    .scaleEffect(x: pose.flipped ? -pose.scaleX : pose.scaleX, y: pose.scaleY, anchor: anchor)
                    .rotationEffect(.degrees(pose.rotation), anchor: anchor)
                    .opacity(pose.opacity)
                    .offset(x: pose.x, y: pose.y - sprite / 2)
                if let emote = pose.emote {
                    // Anchored to the pet's head, not to the top of its sprite
                    // box — the artwork leaves three empty rows up there, and
                    // measuring from the box floated the emote far above it.
                    let headTop = pose.y + sprite * CGFloat(PetBody.headTopFraction)
                    let shoulder = pose.x + sprite * CGFloat(PetBody.shoulderRightFraction)
                    PetEmoteView(emote: emote, scale: pose.emoteScale)
                        .opacity(pose.opacity)
                        .offset(x: shoulder - 2, y: headTop - 7)
                }
            }
            .frame(width: stageWidth, alignment: .top)
            .contentShape(Rectangle())
            // Hovering the pet holds it in place (it can't run off mid-scratch)
            // and tells it where your hand is; clicking it boops it.
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    state.petCursorX = Double(p.x - stageWidth / 2)
                    if activity.isPettable, !state.petPetting { state.petPetting = true }
                case .ended:
                    if state.petPetting { state.petPetting = false }
                }
            }
            .onTapGesture { state.petBoop() }
        }
    }
}

// MARK: - Status bar row

/// Always-visible compact bar shown in the collapsed notch and appended at the
/// bottom of the persistent-notch idle view. Shows the rolling 5-hour cost and
/// weekly cost as labelled mini progress bars relative to their configured caps.
struct StatusBarRow: View {
    @ObservedObject var state: AppState

    /// Display data for one bar slot: bar fill (0...1, nil = no data) and the
    /// right-side label. For `.sessionCost` we skip the fill bar and show raw $.
    private struct BarData {
        var pct: CGFloat?       // nil hides the bar track (cost item); 0...1 fills it
        var text: String        // "38%", "$0.42", or "—"
        var showBar: Bool       // false for session-cost item
        /// "1h 12m" until this limit's window resets. Empty when unknown.
        var resetIn: String = ""
        /// How old this reading is, once it is old enough to matter. Nil = fresh.
        var age: String? = nil
        var tooltip: String = ""
    }

    private func barData(for item: StatusBarItem, showCountdown: Bool) -> BarData {
        switch item {
        case .fiveHourLimit:
            let p = Self.livePercent(state.fiveHourLimitPercent, resetAt: state.fiveHourResetAt)
            return BarData(pct: p, text: p.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", showBar: true,
                           resetIn: showCountdown ? Self.countdown(state.fiveHourResetAt) : "",
                           age: Self.readingAge(state.limitsUpdatedAt),
                           tooltip: limitTooltip("5-hour limit", pct: p, resetAt: state.fiveHourResetAt))
        case .weeklyLimit:
            let p = Self.livePercent(state.weeklyLimitPercent, resetAt: state.weeklyResetAt)
            return BarData(pct: p, text: p.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", showBar: true,
                           resetIn: showCountdown ? Self.countdown(state.weeklyResetAt) : "",
                           age: Self.readingAge(state.limitsUpdatedAt),
                           tooltip: limitTooltip("Weekly limit", pct: p, resetAt: state.weeklyResetAt))
        case .sessionCost:
            return BarData(pct: nil, text: ClaudeUsageReader.fmtMoney(state.currentCostUSD), showBar: false,
                           tooltip: "Estimated cost of this session")
        }
    }

    /// A usage percentage is only worth showing while the window it was measured
    /// in is still running. Past its reset instant it describes a window that no
    /// longer exists, so it becomes "—" until the next status line replaces it.
    /// This is what stops a stale reading sitting there looking like a fact.
    static func livePercent(_ percent: Double, resetAt: Date?) -> CGFloat? {
        guard percent >= 0 else { return nil }
        if let resetAt, resetAt <= Date() { return nil }
        return CGFloat(percent)
    }

    /// The countdown, or nothing once the window it describes has already reset.
    ///
    /// Claude Code only pushes a status line when it redraws, so a reading can
    /// sit in the notch long after it stopped being true. Once its reset instant
    /// is in the past, the percentage beside it is describing a window that no
    /// longer exists, and "0% · now" is a confident-looking lie. Say nothing
    /// instead, until the next status line brings a real number.
    private static func countdown(_ resetAt: Date?) -> String {
        guard let resetAt, resetAt > Date() else { return "" }
        return ClaudeUsageReader.resetCountdown(until: resetAt)
    }

    private static let resetClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func limitTooltip(_ name: String, pct: CGFloat?, resetAt: Date?) -> String {
        var parts: [String] = [name]
        if let pct { parts.append("\(Int((pct * 100).rounded()))% used") }
        if let resetAt {
            parts.append("resets in \(ClaudeUsageReader.resetCountdown(until: resetAt)) "
                         + "(\(Self.resetClockFormatter.string(from: resetAt)))")
        }
        if let age = Self.readingAge(state.limitsUpdatedAt) {
            parts.append("last reported \(age) ago")
        }
        parts.append("Claude Code only reports usage while a session is running")
        return parts.joined(separator: " · ")
    }

    /// How old the newest limit reading is, or nil while it is fresh enough to
    /// pass for current.
    ///
    /// Claude Code reports usage only while a session is redrawing its status
    /// line. Leave Claude idle and the newest reading we have ages quietly, which
    /// is how the notch could sit there showing 31% while `/usage` said 52%. An
    /// old number presented as a current one is worse than no number.
    static let staleAfter: TimeInterval = 5 * 60

    static func readingAge(_ updatedAt: Date?) -> String? {
        guard let updatedAt else { return nil }
        let age = Date().timeIntervalSince(updatedAt)
        guard age >= staleAfter else { return nil }
        return ClaudeUsageReader.ageDescription(seconds: age)
    }

    private func tint(for pct: CGFloat) -> Color {
        switch pct {
        case ..<0.6:  return Color(red: 0.39, green: 0.70, blue: 0.93)
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    private struct BarWidget: View {
        let label: String
        let data: BarData
        let tint: Color

        var body: some View {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
                if data.showBar {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10)).frame(width: 52, height: 3)
                        Capsule().fill(tint.opacity(0.9)).frame(width: 52 * (data.pct ?? 0), height: 3)
                    }
                }
                Text(data.text)
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white.opacity(0.65))
                // "82%" tells you that you are in trouble. It does not tell you
                // whether you can wait it out, which is the thing you actually
                // want to know, and Claude Code reports it.
                if !data.resetIn.isEmpty {
                    Text(data.resetIn)
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.32))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                // An old reading must not pass for a current one.
                if let age = data.age {
                    Text("· \(age) old")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.28))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .help(data.tooltip)
        }
    }

    var body: some View {
        let items = state.statusBarItems
        // Re-render every half minute so the countdowns actually count down.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    let d = barData(for: item, showCountdown: true)
                    BarWidget(label: item.barLabel, data: d, tint: tint(for: d.pct ?? 0))
                    if idx < items.count - 1 { separator }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 11)
            .padding(.horizontal, 14)
    }
}

// MARK: - Idle

private struct IdlePill: View {
    @ObservedObject var state: AppState
    @State private var pulsePhase: Double = 0   // 0→2π, used by SessionsList

    private var canExpand: Bool { !state.fullClaudeResponse.isEmpty }
    private var canShowHistory: Bool { !state.history.isEmpty }
    private var isOpen: Bool { state.persistentNotchDisplay || state.isHovering }
    private var hasMultipleSessions: Bool { state.activeSessionCount >= 2 }

    private var nameText: String {
        hasMultipleSessions
            ? "\(state.entityName) · \(state.activeSessionCount) sessions"
            : state.entityName
    }

    private var statusText: String {
        if state.claudeActionStatus == "thinking" { return "Thinking" }
        if state.isClaudeWorking { return "Running command" }
        return "Ready"
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
            }
        } else {
            Text(statusText)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.38))
                .lineLimit(1)
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
                // Secondary counts — real noise, low urgency. Only worth the
                // pixels when the cursor is actually on the notch (not just
                // when persistentNotchDisplay keeps the card open ambiently).
                if state.isHovering {
                    let agentCount = state.totalRunningAgentCount
                    if agentCount > 0 {
                        Text(agentCount == 1 ? "1 agent" : "\(agentCount) agents")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.purple.opacity(0.95))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.18))
                            .cornerRadius(4)
                    }
                    let fileCount = state.currentTouchedFiles.count
                    if fileCount > 0 {
                        Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.cyan.opacity(0.95))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.15))
                            .cornerRadius(4)
                            .help("Files Claude edited this session — full list in the menu bar")
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

            // Row 2 — model name always shown; version/effort/branch are detail
            // that only earns its space while the cursor is actually here.
            // Context % and cost stay always-visible — the numbers people
            // actually glance at mid-session.
            let (modelName, modelVer) = ClaudeUsageReader.modelNameVersion(state.currentModel)
            HStack(spacing: 5) {
                if !modelName.isEmpty {
                    Text(modelName)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if state.isHovering {
                        if !modelVer.isEmpty {
                            Text(modelVer)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(.white.opacity(0.35))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if !state.currentEffort.isEmpty {
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 2.5, height: 2.5)
                        }
                    }
                }
                if state.isHovering {
                    if !state.currentEffort.isEmpty {
                        Text("\(state.currentEffort) effort")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if !state.currentGitBranch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                            // Elide long branch names ourselves and then hold that
                            // width. Left to the layout, this was the first thing
                            // squeezed when the row got tight, and it did not
                            // stop at "ma…" — it went all the way down to "m",
                            // which reads as a glyph nobody ordered rather than
                            // as a branch.
                            Text(NotchView.elide(state.currentGitBranch, to: 18))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .help("Checked-out git branch: \(state.currentGitBranch)")
                    }
                }
                Spacer(minLength: 0)
                // Highest layout priority in the row — context% and cost are
                // the numbers people actually check mid-session, so they must
                // never be the ones that get squeezed down to "8…" / "$…"
                // when the hover-only detail (version/effort/branch) is showing.
                ContextCostBar(
                    percent: state.currentContextPercent,
                    cost: state.currentCostUSD,
                    // Without the model the bar cannot know how big the window
                    // is, and quietly falls back to the smallest one — which is
                    // how a 1M-window session kept being drawn against 200k.
                    model: state.currentModel,
                    showModelName: false,   // row 2 already names it
                    costCap: state.sessionCostCap,
                    tokens: state.currentContextTokens,
                    window: AppState.windowFor(model: state.currentModel,
                                               reported: state.currentContextWindow,
                                               learned: state.learnedContextWindows,
                                               tokens: state.currentContextTokens,
                                               mode: state.contextWindowMode)
                )
                .layoutPriority(1)
            }

            // Row 3 — command strip, visible only while Claude is active
            if state.isClaudeWorking && !state.lastActivity.isEmpty {
                let parsed = parseActivity(state.lastActivity)
                CommandLineBlock(icon: parsed.icon, text: parsed.text)
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
                            // A background agent is named by the task it was given.
                            // It has no other label: no terminal, no window, and a
                            // folder name tells you nothing about what it is doing.
                            let label: String = {
                                if !session.title.isEmpty { return session.title }
                                if !session.backgroundIntent.isEmpty { return session.backgroundIntent }
                                return session.project.isEmpty ? "session" : session.project
                            }()
                            if !session.backgroundAgentId.isEmpty {
                                Text("AGENT")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundColor(.purple.opacity(0.9))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(Color.purple.opacity(0.18))
                                    )
                                    .help("Running in the background (claude --bg)")
                            }
                            Text(label)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(session.title.isEmpty ? session.cwd
                                      : "\(session.project) — \(session.cwd)")
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
                                        Text("Attach")
                                            .font(.system(size: 9, weight: .medium, design: .rounded))
                                    }
                                    .foregroundColor(.purple.opacity(0.9))
                                }
                                .buttonStyle(.plain)
                                .help("Open this background agent in a terminal (claude attach \(session.backgroundAgentId))")
                            }
                            // The open PR for this branch. Claude Code resolves it,
                            // so the notch can link straight to it instead of the
                            // app shelling out to `gh` to find out it exists.
                            if session.prNumber > 0 {
                                Button {
                                    guard let url = URL(string: session.prURL) else { return }
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
                            Text("compacting context…")
                                .font(.system(size: 9, design: .rounded))
                                .foregroundColor(.orange.opacity(0.8))
                                .padding(.leading, 14)
                        } else if session.hasMeter {
                            ContextCostBar(percent: session.contextPercent,
                                           cost: session.sessionCostUSD,
                                           model: session.model,
                                           costCap: state.sessionCostCap,
                                           tokens: session.contextTokens,
                                           window: AppState.windowFor(model: session.model,
                                                                      reported: session.contextWindow,
                                                                      learned: state.learnedContextWindows,
                                                                      tokens: session.contextTokens,
                                                                      mode: state.contextWindowMode))
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
        let cost = cost > 0  ? " · est. \(ClaudeUsageReader.fmtMoney(cost)) this session" : ""
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
            } else {
                Text("\(Int((percent * 100).rounded()))%")
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundColor(.white.opacity(0.45))
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
    @State private var copied = false

    private func copyReply() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.detailResponseText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

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
                NotchButton(label: copied ? "Copied ✓" : "Copy",
                            style: .secondary, shortcut: "⌘C", action: copyReply)
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
    var onRaiseCap: (() -> Void)? = nil
    var onDisableEnforce: (() -> Void)? = nil
    var raiseCapTarget: Double = 0
    var showPet: Bool = false

    private var isBudgetBlocked: Bool { request.budgetBlock != nil }
    private var accentColor: Color {
        if request.isDangerous { return .red }
        if isBudgetBlocked { return .orange }
        return .yellow
    }
    private var headerIcon: String {
        if request.isDangerous { return "exclamationmark.triangle.fill" }
        if isBudgetBlocked { return "dollarsign.circle.fill" }
        return "exclamationmark.bubble.fill"
    }

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
                // Show how long this card has been waiting once it passes a
                // minute — a quiet cue that Claude has been blocked a while.
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    if Date().timeIntervalSince(request.receivedAt) >= 60 {
                        Text("⏳ waiting \(waitElapsed(request.receivedAt))")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.orange.opacity(0.9))
                    }
                }
                Spacer()
                if !request.cwd.isEmpty {
                    Text((request.cwd as NSString).lastPathComponent)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if request.isDangerous {
                DangerBanner(reasons: request.dangerReasons, showPet: showPet)
            }

            if let block = request.budgetBlock {
                BudgetBanner(block: block, onDisableEnforce: onDisableEnforce)
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
                if !request.isDangerous && !isBudgetBlocked {
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
                } else if isBudgetBlocked {
                    // Over budget: explicit choices only. "Allow once" lets this
                    // one through; "Raise to $X" bumps the cap so the flow
                    // continues. No Enter shortcut — must be deliberate.
                    NotchButton(label: "Allow once", style: .secondary) {
                        onResolve(.allow, .none)
                    }
                    if let onRaiseCap, raiseCapTarget > 0 {
                        NotchButton(label: "Raise to \(ClaudeUsageReader.fmtMoney(raiseCapTarget))",
                                    style: .primary, action: onRaiseCap)
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
    }
}

// MARK: - Danger banner

private struct DangerBanner: View {
    let reasons: [String]
    var showPet: Bool = false
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
            // The pet flinches at a destructive command: looking about,
            // shaking, a startled "!". A second pair of eyes that says "careful".
            if showPet {
                PetCardBadge(size: 30, activity: .lookAround, loop: 1.4,
                             emote: .bang, jitter: true)
                    .frame(width: 30, height: 30)
                    .padding(.leading, 2)
            }
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

// MARK: - Budget banner

private struct BudgetBanner: View {
    let block: BudgetBlock
    var onDisableEnforce: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "dollarsign.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 11, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Over your \(block.scope) budget")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange.opacity(0.95))
                Text("\(ClaudeUsageReader.fmtMoney(block.cost)) of \(ClaudeUsageReader.fmtMoney(block.cap)) cap (\(block.pct)%)")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.85))
            }
            Spacer(minLength: 0)
            if let onDisableEnforce {
                Button("Turn off", action: onDisableEnforce)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .help("Turn off budget enforcement and allow this command")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
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

/// Outcome buckets the history drawer can filter by. `.all` short-circuits;
/// the rest match a single HistoryEntry.Outcome family.
private enum HistoryFilter: String, CaseIterable, Identifiable {
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

private enum HistoryTab: String, CaseIterable {
    case sessions = "Sessions"
    case projects = "Projects"
    case events   = "Events"
}

private struct ProjectStats: Identifiable {
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

private struct HistoryCard: View {
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
        for r in state.sessionHistory { grouped[r.project, default: []].append(r) }
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
                            SessionHistoryRow(record: record, onResume: { resume(in: record.cwd) })
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

private struct SessionHistoryRow: View {
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

private struct ProjectStatsRow: View {
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

/// A small pet, looping one activity, for use inside a card (not the notch, so
/// no drop-out-of-the-lip envelope — it just stands there and performs). Purely
/// decorative: nothing depends on it, so a card reads fine with Pet Mode off.
private struct PetCardBadge: View {
    var size: CGFloat = 34
    var activity: PetActivity = .celebrate
    var loop: Double = 2.4          // seconds per cycle
    var emote: PetEmote? = nil      // a glyph beside the head (e.g. a startled !)
    var jitter: Bool = false        // a fast nervous shake, for the danger card
    var dance: Bool = false         // the full four-beat routine (task-complete card)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { tl in
            let clock = tl.date.timeIntervalSinceReferenceDate
            let t = clock.truncatingRemainder(dividingBy: loop) / loop
            if dance {
                let f = PetRigging.dance(progress: t, time: clock)
                PetSprite(size: size, rig: f.rig)
                    .rotationEffect(.degrees(f.rotation))
                    .offset(x: CGFloat(f.offsetX) * size, y: CGFloat(-f.offsetY) * size)
                    .frame(width: size, height: size, alignment: .bottom)
            } else {
                let rig = PetRigging.rig(for: activity, progress: t, time: clock)
                // The rig handles the limbs; the whole-body hop/bob is card-local
                // so it doesn't drag in PetEngine's notch geometry.
                let lift: CGFloat = {
                    switch activity {
                    case .celebrate: return CGFloat(abs(sin(t * 3 * .pi))) * size * 0.28
                    case .peek, .lookAround: return CGFloat(sin(t * 2 * .pi)) * size * 0.04
                    default: return 0
                    }
                }()
                let shake: CGFloat = jitter ? CGFloat(sin(clock * 22)) * size * 0.045 : 0
                ZStack {
                    PetSprite(size: size, rig: rig)
                        .offset(x: shake, y: -lift)
                    if let emote {
                        // Above and just past the right of the head — same
                        // landmarks the notch emote uses, so it sits on the
                        // creature and not the empty box around it.
                        PetEmoteView(emote: emote, scale: 1)
                            .offset(x: shake + size * CGFloat(PetBody.shoulderRightFraction) - 2,
                                    y: -lift + size * CGFloat(PetBody.headTopFraction) - 3)
                    }
                }
                .frame(width: size, height: size, alignment: .bottom)
            }
        }
    }
}

private struct CompletedCard: View {
    let task: CompletedTask
    var showPet: Bool = false
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
                // The pet turns up to dance out a finished task.
                if showPet {
                    PetCardBadge(size: 32, loop: 3.4, dance: true)
                        .frame(width: 32, height: 32)
                }
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

private let timeAgoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM"   // "9 Jul"
    return f
}()

private func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    let m = s / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    if h < 24 { return "\(h)h ago" }
    let d = h / 24
    // Past a week "312h ago" / even "13d ago" stops meaning anything — show the
    // actual date instead.
    if d <= 7 { return "\(d)d ago" }
    return timeAgoDateFormatter.string(from: date)
}

/// Compact elapsed-wait label: "45s", "3m", "1h 20m".
private func waitElapsed(_ since: Date) -> String {
    let s = Int(Date().timeIntervalSince(since))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60; let rm = m % 60
    return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
}

/// Badge for non-default Claude Code permission modes. `default` (and empty)
/// return nil — no badge for the normal case. bypassPermissions is the loud
/// one: every action runs unchecked, so it's red and impossible to miss.
///
/// `acceptEdits` gets no badge either: auto-accepting file edits is a normal
/// way to work rather than something you need warning about, and the badge sat
/// in the notch permanently for anyone who works that way.
func permissionModeBadge(_ mode: String) -> (label: String, color: Color, help: String)? {
    switch mode {
    case "bypassPermissions":
        return ("BYPASS", .red, "Permissions are bypassed — every action runs without asking")
    case "plan":
        return ("PLAN", .blue, "Plan mode — Claude is planning, not editing")
    case "auto":
        return ("AUTO", .teal, "Auto mode — background safety checks approve safe actions")
    case "dontAsk":
        return ("DON'T ASK", .orange, "Don't-ask mode — most actions run without prompting")
    default:
        return nil
    }
}
