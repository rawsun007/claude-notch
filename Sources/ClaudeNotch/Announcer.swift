import AppKit

/// Speaks a card out loud to VoiceOver.
///
/// The notch is a borderless panel that deliberately does NOT steal focus — the
/// whole point of the app is that your keyboard stays in the terminal. That is
/// good for sighted users and invisible to VoiceOver: nothing moves the cursor,
/// so a blocking Allow/Deny card can sit there unread while Claude waits.
///
/// An announcement fixes that without touching focus. It is posted against the
/// app element rather than a view, so it works no matter which window is key.
enum Announcer {
    /// Whether anything is listening. Checked before building the string so the
    /// common (VoiceOver off) path costs nothing.
    static var isVoiceOverRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// Speak `message`. `.high` interrupts whatever VoiceOver is saying, which
    /// is what a blocking card wants; `.medium` waits its turn.
    static func say(_ message: String, priority: NSAccessibilityPriorityLevel = .high) {
        guard isVoiceOverRunning else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue,
            ]
        )
    }

    /// The spoken form of a permission ask, including how to answer it. Pure so
    /// it can be tested, and so the phrasing lives next to `say`.
    ///
    /// The keys quoted here must match `KeyboardMonitor.handleKey`. Return
    /// resolves the WHOLE queue when more than one card is waiting, so that
    /// case is spoken differently — announcing a plain "press Return to allow"
    /// would let someone approve several commands they never heard.
    nonisolated static func announcement(for r: PermissionRequest, pending: Int) -> String {
        var parts = [PermissionCard.spokenAsk(for: r)]
        switch r.kind {
        case .toolUse:
            if r.isDangerous {
                parts.append("Escape denies. This one is destructive, so allowing it needs a deliberate confirmation on the card.")
            } else if r.budgetBlock != nil {
                parts.append("Escape denies. This one is over budget, so allowing it needs an explicit choice on the card.")
            } else if pending > 1 {
                parts.append("\(pending) requests are waiting, and Return would allow all \(pending). Escape denies this one.")
            } else {
                parts.append("Return allows. Escape denies.")
            }
        case .notification:
            parts.append("Escape dismisses.")
        }
        return parts.joined(separator: " ")
    }

    /// The spoken form of a question card: the prompt plus its options. There
    /// are no per-option keys, so the wording sends the user to the buttons.
    nonisolated static func announcement(for q: QuestionRequest) -> String {
        var parts: [String] = ["Claude has a question."]
        for question in q.questions {
            parts.append(question.header.isEmpty ? question.text : "\(question.header). \(question.text)")
            let options = question.options.map(\.label)
            if !options.isEmpty {
                parts.append("Options: " + options.joined(separator: ", ") + ".")
            }
        }
        parts.append("Choose an option on the card, or press Escape to dismiss.")
        return parts.joined(separator: " ")
    }
}
