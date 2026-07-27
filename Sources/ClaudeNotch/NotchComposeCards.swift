import SwiftUI
import AppKit

// Compose, response detail, and thinking cards.



// MARK: - Compose

struct ComposeCard: View {
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
                        Text(L("Open in project", comment: "Menu label: start a new session in a chosen project"))
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
                    // The placeholder is a sibling Text the editor never adopts,
                    // so unlabelled this is an unnamed text area.
                    .accessibilityLabel(placeholder)
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

struct ResponseDetailCard: View {
    @ObservedObject var state: AppState
    @State private var copied = false

    private func copyReply() {
        NSPasteboard.copyString(state.detailResponseText)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Claude's last reply", comment: "Heading of the expanded reply card"))
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

struct ThinkingPill: View {
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
