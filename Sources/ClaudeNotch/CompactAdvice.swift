import Foundation

// When to suggest compacting, and when to keep quiet about it.
//
// Compacting is the habit that separates people who get good work out of a long
// session from people who watch it degrade. Do it deliberately, around half a
// window, and the summary is written while the conversation still makes sense.
// Leave it, and auto-compact fires on its own schedule, which in practice is
// while you are in the middle of the last thing you asked for.
//
// The notch already draws the context bar, so it knows the number before the
// user does. Saying something is the whole feature.
//
// The hard part is not the threshold, it is not becoming another thing people
// switch off. So: once per session per crossing, never while the session is
// mid-answer, and nothing at all for a session that will not live long enough
// to care.
enum CompactAdvice {

    /// Where to speak up.
    ///
    /// Half a window is the number the people who do this deliberately use. It
    /// is early enough that the summary is written from a conversation that
    /// still has its shape, and late enough that a short session never hears
    /// about it at all.
    static let suggestAt = 0.55

    /// Past this, auto-compact is close and the advice changes from "a good
    /// moment" to "before it happens to you".
    static let urgentAt = 0.80

    enum Urgency: Equatable {
        case none
        /// A good moment to compact, said once.
        case suggested
        /// Auto-compact is coming; better to choose when.
        case urgent
    }

    /// What, if anything, to say about a session's context.
    ///
    /// `alreadySaid` is the highest level already shown for this session, so
    /// crossing the same line twice says nothing and crossing the next one
    /// still does.
    nonisolated static func urgency(percent: Double, alreadySaid: Urgency) -> Urgency {
        let level: Urgency = {
            if percent >= urgentAt { return .urgent }
            if percent >= suggestAt { return .suggested }
            return .none
        }()
        // Only ever escalate. Falling back below a threshold is what compacting
        // does, and re-announcing on the way down would be the app talking
        // about its own advice being taken.
        switch (alreadySaid, level) {
        case (.urgent, _):            return .none
        case (.suggested, .urgent):   return .urgent
        case (.suggested, _):         return .none
        case (.none, let l):          return l
        }
    }

    nonisolated static func title(_ urgency: Urgency, percent: Double) -> String {
        let pct = Int((percent * 100).rounded())
        switch urgency {
        case .none:
            return ""
        case .suggested:
            return String(format: L("Context is %d%% full. Good moment to compact.",
                                    comment: "Card title suggesting the user compact. %d is a percentage"),
                          pct)
        case .urgent:
            return String(format: L("Context is %d%% full. Compact before it happens on its own.",
                                    comment: "Card title when auto-compact is close. %d is a percentage"),
                          pct)
        }
    }

    nonisolated static func detail(_ urgency: Urgency) -> String {
        switch urgency {
        case .none:
            return ""
        case .suggested:
            return L("Compacting now writes the summary while the conversation still has its shape. Left alone, Claude Code will do it on its own schedule, which tends to be in the middle of the next thing you ask for.",
                     comment: "Card body suggesting a deliberate compaction")
        case .urgent:
            return L("Auto-compaction is close. Doing it now means it happens between two things rather than inside one.",
                     comment: "Card body when auto-compaction is imminent")
        }
    }

    /// Whether this session is worth advising at all.
    ///
    /// A session with no meter has told us nothing, and one that is mid-answer
    /// is the worst possible moment: the advice is to interrupt, and it would
    /// arrive as an interruption.
    nonisolated static func worthAdvising(hasMeter: Bool, isWorking: Bool,
                                          isCompacting: Bool) -> Bool {
        hasMeter && !isWorking && !isCompacting
    }
}
