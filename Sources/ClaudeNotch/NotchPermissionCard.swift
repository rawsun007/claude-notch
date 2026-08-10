import SwiftUI
import AppKit

// The blocking permission card, its banners, previews, and hold-to-confirm.



// MARK: - Permission (blocking, tool use)

struct PermissionCard: View {
    /// A whole permission ask as one spoken sentence for VoiceOver. Pure so it
    /// can be tested, and so the phrasing lives in one place. `nonisolated`
    /// because Announcer builds announcements off the main actor.
    nonisolated static func spokenAsk(for r: PermissionRequest) -> String {
        var parts: [String] = []
        if r.isDangerous { parts.append("Dangerous.") }
        parts.append(r.title)
        if !r.toolName.isEmpty, r.toolName != "Notification" { parts.append("Tool: \(r.toolName).") }
        // Redacted: VoiceOver reads this out loud, and a spoken credential
        // carries further than a displayed one.
        if !r.detail.isEmpty { parts.append(SecretRedactor.redact(r.detail)) }
        return parts.joined(separator: " ")
    }

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
    /// How many times this exact command has already been approved by hand.
    /// Zero means say nothing: the nudge is for a habit, not a second time.
    var priorApprovals: Int = 0

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
    /// The header row as one phrase: who is asking, with which tool, in which
    /// project, and how long it has been blocked.
    private var headerSpoken: String {
        var parts: [String] = []
        if request.isDangerous { parts.append("Destructive.") }
        else if isBudgetBlocked { parts.append("Over budget.") }
        parts.append("\(request.source), \(request.toolName).")
        if !request.cwd.isEmpty {
            parts.append("Project \((request.cwd as NSString).lastPathComponent).")
        }
        if Date().timeIntervalSince(request.receivedAt) >= 60 {
            parts.append("Waiting \(waitElapsed(request.receivedAt)).")
        }
        return parts.joined(separator: " ")
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
                        Text(String(format: L("⏳ waiting %@", comment: "Permission card. %@ is an elapsed duration such as \"2m 05s\""), waitElapsed(request.receivedAt)))
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
            // The header is a row of glyphs and fragments. Merged, it reads as
            // one phrase instead of "exclamationmark triangle fill", "·", …
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(headerSpoken)

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
                // VoiceOver reads the whole ask as one phrase: what it is, the
                // tool, the command, and a spoken warning when it is dangerous.
                .accessibilityLabel(Self.spokenAsk(for: request))

            if !request.detail.isEmpty {
                // The notch sits on screen through every screen share and
                // recording. The value of a credential is never what makes
                // a command allowable, so it does not need to be here.
                Text(SecretRedactor.redact(request.detail))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .accessibilityHidden(true)
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
                NotchButton(label: L("Deny", comment: "Button: refuse the permission request"), style: .destructive, shortcut: "⎋") {
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
                    .help("Deny with a reason, tell Claude what to do instead")
                    // Icon-only, so .help alone leaves VoiceOver reading the
                    // SF Symbol name. Same for every icon button below.
                    .accessibilityLabel("Deny with a reason")
                    .accessibilityHint("Tell Claude what to do instead")
                }
                if !request.isDangerous && !isBudgetBlocked {
                    Menu {
                        Button(L("Always Allow This Exact Command", comment: "Menu item: add an allow rule for this exact command")) {
                            onResolve(.allow, .exactCommand)
                        }
                        Button(String(format: L("Always Allow All %@", comment: "Menu item: add an allow rule for every call of a tool. %@ is the tool name"), request.toolName)) {
                            onResolve(.allow, .tool)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(L("Always Allow…", comment: "Menu button opening the always-allow choices"))
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
                    .accessibilityLabel("Always allow")
                    .accessibilityHint("Choose to always allow this exact command, or every \(request.toolName) call")

                    // The button has always been here and hardly anyone uses
                    // it: mid-flow the fastest key is Return, and making a rule
                    // is admin for later. Once the same command has been waved
                    // through several times, say so, at the one moment the
                    // answer is obvious.
                    if priorApprovals > 0 {
                        Text(String(format: L("allowed %d times", comment: "Hint next to Always Allow. %d is how many times this exact command was approved before"), priorApprovals))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .fixedSize()
                            .accessibilityLabel(String(format: L("You have allowed this command %d times before", comment: "VoiceOver form of the repeat-approval hint"), priorApprovals))
                    }
                }
                Spacer()
                if request.isDangerous {
                    if useTouchID {
                        // Biometric confirm for destructive commands. The system
                        // sheet appears; only a successful auth allows it.
                        Button {
                            BiometricAuth.confirm(reason: "allow this command: \(String(SecretRedactor.redact(request.detail).prefix(80)))") { ok in
                                if ok { onResolve(.allow, .none) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: BiometricAuth.iconName)
                                Text(L("Confirm to Allow", comment: "Button: allow a destructive command after biometric confirmation"))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule(style: .continuous).fill(Color.red.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Confirm with \(BiometricAuth.label) to run this destructive command")
                        .accessibilityLabel("Confirm to allow")
                        .accessibilityHint("This command is destructive. Confirms with \(BiometricAuth.label) before running it")
                    } else {
                        HoldToConfirmButton(label: L("Hold to Allow", comment: "Button: press and hold to allow a destructive command"), duration: 0.9) {
                            onResolve(.allow, .none)
                        }
                    }
                } else if isBudgetBlocked {
                    // Over budget: explicit choices only. "Allow once" lets this
                    // one through; "Raise to $X" bumps the cap so the flow
                    // continues. No Enter shortcut — must be deliberate.
                    NotchButton(label: L("Allow once", comment: "Button: allow a single over-budget command without raising the cap"), style: .secondary) {
                        onResolve(.allow, .none)
                    }
                    if let onRaiseCap, raiseCapTarget > 0 {
                        NotchButton(label: String(format: L("Raise to %@", comment: "Button: raise the spending cap. %@ is a money amount"), (request.budgetBlock ?? BudgetBlock(scope: "", cost: 0, cap: 0)).amount(raiseCapTarget)),
                                    style: .primary, action: onRaiseCap)
                    }
                } else if pendingCount > 1, let onResolveAll {
                    // Multiple permissions queued (e.g. several edits at once)
                    // — one tap approves them all.
                    NotchButton(label: L("Allow", comment: "Button: approve the permission request"), style: .secondary) {
                        onResolve(.allow, .none)
                    }
                    NotchButton(label: String(format: L("Allow All (%d)", comment: "Button: approve every queued request. %d is how many"), pendingCount), style: .primary, shortcut: "⏎") {
                        onResolveAll(.allow)
                    }
                } else {
                    NotchButton(label: L("Allow", comment: "Button: approve the permission request"), style: .primary, shortcut: "⏎") {
                        onResolve(.allow, .none)
                    }
                }
            }
            .padding(.top, 18)
        }
    }
}

// MARK: - Danger banner

struct DangerBanner: View {
    let reasons: [String]
    var showPet: Bool = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 11, weight: .bold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("This command is destructive", comment: "Heading of the danger banner"))
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
        // The bullets are the whole point of the warning, so keep them in the
        // label rather than letting each become its own stop.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            (["This command is destructive."] + reasons).joined(separator: " ")
        )
    }
}

// MARK: - Budget banner

struct BudgetBanner: View {
    let block: BudgetBlock
    var onDisableEnforce: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: block.unit == .tokens ? "circle.hexagongrid.fill" : "dollarsign.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 11, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: L("Over your %@ budget", comment: "Budget block. %@ is a scope such as daily or weekly"), block.scope))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange.opacity(0.95))
                Text(String(format: L("%1$@ of %2$@ cap (%3$d%%)",
                                      comment: "Budget block detail. %1$@ is spend, %2$@ is the cap, %3$d is a percentage"),
                          block.amount(block.cost),
                          block.amount(block.cap), block.pct))
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.85))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Over your \(block.scope) budget. \(block.amount(block.cost)) of a \(block.amount(block.cap)) cap, \(block.pct) percent.")
            Spacer(minLength: 0)
            if let onDisableEnforce {
                Button(L("Turn off", comment: "Button: stop enforcing the spending cap"), action: onDisableEnforce)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .help("Turn off budget enforcement and allow this command")
                    .accessibilityLabel("Turn off budget enforcement")
                    .accessibilityHint("Stops blocking commands when you are over your \(block.scope) cap")
            }
        }
        .accessibilityElement(children: .contain)
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

struct PreviewBlock: View {
    let preview: ToolPreview

    var body: some View {
        switch preview {
        case .diff(let hunk):
            DiffPreviewView(hunk: hunk)
        case .multiDiff(let count, let hunk):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: L("First of %d edits", comment: "Multi-edit preview heading. %d is the number of edits"), count))
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

struct DiffPreviewView: View {
    let hunk: DiffHunk

    /// The hunk as one spoken passage. The red/green colouring and the −/+
    /// markers are the whole signal for a sighted user and carry none for a
    /// screen reader, so each side is named. Pure, so it can be tested.
    nonisolated static func spoken(_ hunk: DiffHunk) -> String {
        var parts: [String] = []
        if !hunk.oldLines.isEmpty {
            parts.append("Removing \(hunk.oldLines.count) line\(hunk.oldLines.count == 1 ? "" : "s"):")
            parts.append(contentsOf: hunk.oldLines)
            if hunk.truncatedOld { parts.append("and more.") }
        }
        if !hunk.newLines.isEmpty {
            parts.append("Adding \(hunk.newLines.count) line\(hunk.newLines.count == 1 ? "" : "s"):")
            parts.append(contentsOf: hunk.newLines)
            if hunk.truncatedNew { parts.append("and more.") }
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " ")
    }

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
        // One element, not one per line: the diff is what you are deciding on,
        // so it should read as a passage rather than force line-by-line
        // navigation through a card that is blocking the session.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(hunk))
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

struct WritePreviewView: View {
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
                Text({
                    let more = totalLines - ToolPreviewParser.maxWriteLines
                    return more == 1 ? L("…and 1 more line", comment: "Truncated file preview, singular")
                        : String(format: L("…and %d more lines", comment: "Truncated file preview. %d is 2 or more"), more)
                }())
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        let extra = totalLines - ToolPreviewParser.maxWriteLines
        var text = "Writing \(totalLines) line\(totalLines == 1 ? "" : "s"). \(head)"
        if extra > 0 { text += " and \(extra) more line\(extra == 1 ? "" : "s")." }
        return text
    }
}

// MARK: - Hold-to-confirm button

struct HoldToConfirmButton: View {
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
            .help("Press and hold to confirm, this command was flagged as destructive")
            // A bare DragGesture is invisible to VoiceOver: no trait, no way to
            // activate it. Without this the destructive path is not merely
            // awkward, it is unreachable, and the only option left is Deny.
            // Press-and-hold has no assistive equivalent, so the deliberate act
            // becomes "navigate to this specific control and activate it", and
            // the label says plainly what activating does.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("This command is destructive. Activating runs it")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onConfirm() }
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
