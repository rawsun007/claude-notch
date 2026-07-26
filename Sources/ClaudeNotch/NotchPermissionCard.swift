import SwiftUI
import AppKit

// The blocking permission card, its banners, previews, and hold-to-confirm.



// MARK: - Permission (blocking, tool use)

struct PermissionCard: View {
    /// A whole permission ask as one spoken sentence for VoiceOver. Pure so it
    /// can be tested, and so the phrasing lives in one place.
    static func spokenAsk(for r: PermissionRequest) -> String {
        var parts: [String] = []
        if r.isDangerous { parts.append("Dangerous.") }
        parts.append(r.title)
        if !r.toolName.isEmpty, r.toolName != "Notification" { parts.append("Tool: \(r.toolName).") }
        if !r.detail.isEmpty { parts.append(r.detail) }
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
                // VoiceOver reads the whole ask as one phrase: what it is, the
                // tool, the command, and a spoken warning when it is dangerous.
                .accessibilityLabel(Self.spokenAsk(for: request))

            if !request.detail.isEmpty {
                Text(request.detail)
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

struct BudgetBanner: View {
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

struct PreviewBlock: View {
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

struct DiffPreviewView: View {
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
