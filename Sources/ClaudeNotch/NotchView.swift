import SwiftUI
import AppKit

struct NotchView: View {
    @ObservedObject var state: AppState

    /// How much vertical space is hidden by the physical notch (or 0 if none).
    static func notchInset(on screen: NSScreen?) -> CGFloat {
        guard let screen, screen.safeAreaInsets.top > 0 else { return 0 }
        return screen.safeAreaInsets.top
    }

    static func size(for mode: NotchMode, hovering: Bool = false, on screen: NSScreen? = nil) -> CGSize {
        let s = screen ?? NSScreen.main
        let inset = notchInset(on: s)   // visible content lives below this
        switch mode {
        case .idle:
            return hovering
                ? CGSize(width: 300, height: inset + 36)
                : collapsedSize(on: s)
        case .thinking:
            return CGSize(width: 320, height: inset + 36)
        case .permission(let req):
            return req.kind == .toolUse
                ? CGSize(width: 580, height: inset + 180)
                : CGSize(width: 500, height: inset + 130)
        case .completed:
            return CGSize(width: 500, height: inset + 124)
        case .question(let q):
            let perQuestion: CGFloat = 28 + 12 + CGFloat(q.questions.first?.options.count ?? 1) * 30
            let visible = max(180, 70 + CGFloat(q.questions.count) * perQuestion)
            return CGSize(width: 600, height: min(inset + visible, inset + 520))
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
        ZStack(alignment: .top) {
            NotchShape(cornerRadius: cornerRadius)
                .fill(Color.black)
                .overlay(
                    NotchShape(cornerRadius: cornerRadius)
                        .stroke(borderColor, lineWidth: 1)
                )
                .shadow(color: .black.opacity(showShadow ? 0.55 : 0), radius: 20, x: 0, y: 12)

            if !isCollapsedIdle {
                content
                    .padding(.horizontal, 18)
                    .padding(.top, NotchView.notchInset(on: NSScreen.main) + 8)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isCollapsedIdle: Bool {
        if case .idle = state.mode, !state.isHovering { return true }
        return false
    }

    private var showShadow: Bool {
        if case .idle = state.mode { return false }
        return true
    }

    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .idle:
            IdlePill()
                .transition(.opacity)
        case .thinking(let label):
            ThinkingPill(label: label)
                .transition(.opacity)
        case .permission(let req):
            if req.kind == .toolUse {
                PermissionCard(request: req) { decision, alwaysAllow in
                    state.resolveCurrentPermission(decision, alwaysAllow: alwaysAllow)
                }
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else {
                NotificationCard(request: req, onOpen: {
                    state.openOriginator(req.originatorBundleID)
                    state.resolveCurrentPermission(.ask)
                }, onDismiss: {
                    state.resolveCurrentPermission(.ask)
                })
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        case .completed(let task):
            CompletedCard(task: task, onOpen: {
                state.openOriginator(task.originatorBundleID)
                state.dismissCurrentCompleted()
            }, onDismiss: {
                state.dismissCurrentCompleted()
            })
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        case .question(let req):
            QuestionCard(request: req, onSubmit: { answers in
                state.resolveCurrentQuestion(answers)
            }, onCancel: {
                state.resolveCurrentQuestion(nil)
            })
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    private var cornerRadius: CGFloat {
        if isCollapsedIdle { return 9 }   // small radius matching Mac notch curve
        switch state.mode {
        case .idle:        return 14
        case .thinking:    return 16
        case .permission, .completed, .question: return 22
        }
    }

    private var borderColor: Color {
        if isCollapsedIdle { return .clear }
        // Unified subtle hairline — keep the visual cleanly "notch-black",
        // status is communicated by the icon, not the border.
        return Color.white.opacity(0.07)
    }
}

/// Flat top, rounded bottom — hangs from the top edge of the display like a
/// notch / dynamic island. SwiftUI's coordinates put minY at the top.
private struct NotchShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Idle

private struct IdlePill: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("ClaudeNotch")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
            Spacer(minLength: 0)
            Text("idle")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
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
    let onResolve: (PermissionDecision, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 14, weight: .semibold))
                Text(request.source)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.yellow.opacity(0.9))
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

            HStack(spacing: 8) {
                NotchButton(label: "Deny", style: .destructive, shortcut: "⎋") {
                    onResolve(.deny, false)
                }
                NotchButton(label: "Always allow \(request.toolName)", style: .secondary) {
                    onResolve(.allow, true)
                }
                Spacer()
                NotchButton(label: "Allow", style: .primary, shortcut: "⏎") {
                    onResolve(.allow, false)
                }
            }
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
            .frame(maxHeight: 360)

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

private func timeAgo(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    let m = s / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    return "\(h)h ago"
}
