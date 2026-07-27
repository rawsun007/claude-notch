import SwiftUI
import AppKit

// The non-blocking cards: notification, completed, auto-approved, question.



// MARK: - Notification (non-blocking)

struct NotificationCard: View {
    let request: PermissionRequest
    var showPet: Bool = false
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
                // Same spot the done card puts its dancing pet: top-right of the
                // header. Here the mascot cries over the limit instead.
                if showPet, request.toolName == "RateLimit" {
                    PetCardBadge(size: 32, activity: .fret, loop: 1.6, emote: .teardrop)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
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
                    NotchButton(label: NSLocalizedString("Dismiss", comment: "Button: close a notification card"), style: .secondary, action: onDismiss)
                    NotchButton(label: NSLocalizedString("Open IDE", comment: "Button: bring the editor or terminal that started this session to the front"), style: .primary, action: onOpen)
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
struct PetCardBadge: View {
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

struct CompletedCard: View {
    let task: CompletedTask
    var showPet: Bool = false
    var onReply: (() -> Void)? = nil
    let onOpen: () -> Void
    let onDismiss: () -> Void
    private let rowSpacing: CGFloat = 14

    /// How the audit reads on the card. A contradiction is the only one drawn
    /// in a warning colour: the other two are context, not an alarm.
    private var auditLine: (text: String, tint: Color, icon: String)? {
        guard let message = task.audit.message else { return nil }
        switch task.audit {
        case .contradicted: return (message, .orange, "exclamationmark.triangle.fill")
        case .unverified:   return (message, .white.opacity(0.55), "questionmark.circle")
        case .verified:     return (message, .green.opacity(0.85), "checkmark.circle")
        case .silent:       return nil
        }
    }

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

            if let verdict = auditLine {
                AuditBanner(text: verdict.text, tint: verdict.tint, icon: verdict.icon)
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
                        NotchButton(label: NSLocalizedString("Reply", comment: "Button: open a composer to send a follow-up message"), style: .secondary, action: onReply)
                    }
                    NotchButton(label: NSLocalizedString("Open IDE", comment: "Button: bring the editor or terminal that started this session to the front"), style: .secondary, action: onOpen)
                    NotchButton(label: NSLocalizedString("Done", comment: "Button: dismiss the finished-task card"), style: .primary, action: onDismiss)
                }
                .fixedSize()
            }
        }
    }
}

/// The completion audit's line on a finished task. Same shape as the danger and
/// budget banners on the permission card, so a warning looks the same wherever
/// it turns up.
struct AuditBanner: View {
    let text: String
    let tint: Color
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - Auto-approved (info only, no buttons)

struct AutoInfoCard: View {
    let request: PermissionRequest
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.badge.checkmark.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .semibold))
                Text(NSLocalizedString("Auto-allowed", comment: "Heading: this action was approved automatically by a rule"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.green.opacity(0.9))
                    .textCase(.uppercase)
                Text("·").foregroundColor(.white.opacity(0.3))
                Text(request.toolName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Text(NSLocalizedString("click to dismiss", comment: "Hint under the auto-allowed card"))
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

struct NotchButton: View {
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
        // VoiceOver reads the plain label, not the "Copied ✓" state text or the
        // "⌘↩" glyph, and hears "destructive" as a warning on Deny.
        .accessibilityLabel(label.replacingOccurrences(of: " ✓", with: ""))
        .accessibilityHint(shortcut.map { "shortcut \($0)" } ?? "")
        .accessibilityAddTraits(style == .destructive ? [.isButton] : .isButton)
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

struct QuestionCard: View {
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
                                    .fixedSize(horizontal: false, vertical: true)
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
                NotchButton(label: NSLocalizedString("Cancel", comment: "Button: abandon answering the question"), style: .secondary, action: onCancel)
                NotchButton(label: NSLocalizedString("Send", comment: "Button: submit the answer to Claude's question"), style: .primary) {
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
            .accessibilityLabel("Your own answer")
            .accessibilityHint("Type an answer if none of the options fit")
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
                        // The description is the answer to "what does this option
                        // do". Clipping it to one line hides exactly the part you
                        // open the card to read. The card scrolls, so it can wrap.
                        Text(opt.description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
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
        // Selection is drawn purely as a filled-in symbol, which says nothing
        // out loud. The trait is what makes VoiceOver speak "selected", and it
        // is the only way to tell a picked option from an unpicked one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(opt.description.isEmpty ? opt.label : "\(opt.label). \(opt.description)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(q.multiSelect ? "Choose one or more" : "Choose one")
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
