import Foundation

// When the model under a session changes without anyone saying so.
//
// This is one of the better-documented complaints about Claude Code and one
// nothing surfaces: Opus falls back to Sonnet on hitting a cap, a new session
// silently starts on Sonnet despite Opus being chosen, re-authenticating
// downgrades the session, an account is served Haiku for hours. In every report
// the same sentence appears in some form: there was no notification, and no
// clear indication of which model was actually active.
//
// The notch already knows. `LiveSession.model` is updated from the status line
// on every turn, so the change is sitting in front of us and is simply never
// compared against what it was a moment ago.
//
// The hard part is not detecting a change, it is not crying wolf. A user who
// types `/model sonnet` has changed the model deliberately and must not be told
// their session was downgraded. This app has made exactly that mistake before,
// with managed-settings restrictions read as evidence of an organisation, so
// the rules here are deliberately narrow and the wording deliberately neutral:
// state what changed, do not assert why.
//
// Pure and nonisolated: it is string comparison, and the shapes it must survive
// are worth pinning in tests rather than discovering on someone's cap day.
enum ModelDrift {

    /// The three Claude tiers, ordered by capability.
    ///
    /// `unknown` is not a tier, it is the absence of one, and it is the reason
    /// this enum exists rather than a bare comparison. A model this app has
    /// never heard of must produce no card at all: guessing that an unfamiliar
    /// id ranks below a familiar one is how you tell somebody they were
    /// downgraded onto a model that is actually newer.
    enum Tier: Int, Comparable, Sendable {
        case unknown = 0
        case haiku = 1
        case sonnet = 2
        case opus = 3

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// The tier family named in a model id, or `.unknown`.
    ///
    /// Matched on the family word rather than the whole id so version bumps
    /// (`claude-opus-4-5` -> `claude-opus-5`) resolve to the same tier.
    nonisolated static func tier(_ model: String) -> Tier {
        let m = model.lowercased()
        if m.contains("opus") { return .opus }
        if m.contains("sonnet") { return .sonnet }
        if m.contains("haiku") { return .haiku }
        return .unknown
    }

    /// The family word itself, for wording the card. Empty when unknown.
    nonisolated static func family(_ model: String) -> String {
        switch tier(model) {
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .unknown: return ""
        }
    }

    struct Change: Equatable, Sendable {
        /// The family the session was on, e.g. "Opus".
        var from: String
        /// The family it is on now, e.g. "Sonnet".
        var to: String
    }

    /// Whether a model change is worth putting on screen, and as what.
    ///
    /// Returns nil for everything that is not a tier drop, which is most
    /// changes:
    ///
    /// - Nothing changed, or either side is empty (a session that has not
    ///   reported a model yet is not a session that changed model).
    /// - A version bump inside one family. `claude-opus-4-8` to
    ///   `claude-opus-5` is the same tier and is nobody's problem.
    /// - Either side is a model this app cannot rank, including non-Claude
    ///   models and Claude models it has not been taught. Silence beats a
    ///   guess.
    /// - A move UP a tier. Sonnet to Opus is not a complaint anyone filed, and
    ///   announcing it would mean interrupting people with good news.
    ///
    /// What survives is only a drop in tier: Opus to Sonnet, Opus to Haiku,
    /// Sonnet to Haiku. That is the shape every one of the reported issues has.
    nonisolated static func change(from before: String, to after: String) -> Change? {
        let a = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty, a != b else { return nil }

        let old = tier(a), new = tier(b)
        guard old != .unknown, new != .unknown else { return nil }
        guard new < old else { return nil }

        return Change(from: family(a), to: family(b))
    }

    // MARK: - What it says

    nonisolated static func cardTitle(_ change: Change) -> String {
        String(format: L("This session is now on %@, not %@",
                         comment: "Card title when a session's model dropped to a lower tier. First %@ is the new model family, second is the old one"),
               change.to, change.from)
    }

    /// Deliberately does not assert a cause.
    ///
    /// A drop can be a plan cap, a re-authentication, or the user's own
    /// `/model`. The app cannot tell which, and the honest card names the two
    /// possibilities rather than picking the alarming one. Saying "you were
    /// downgraded" to somebody who switched on purpose is the same class of
    /// error as telling a personal Mac it has an organisation.
    nonisolated static func cardDetail(_ change: Change) -> String {
        String(format: L("It started on %@. Either you switched it, or your plan moved it. Claude Code does not say which, so this is only the change itself.",
                         comment: "Card body when a session's model dropped a tier. %@ is the model family it started on"),
               change.from)
    }
}
