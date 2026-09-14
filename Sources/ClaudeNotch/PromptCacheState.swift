import Foundation

/// A session's prompt-cache state, from the status line's `prompt_cache` object
/// (Claude Code 2.1.251+).
///
/// Why the notch cares, in Claude Code's own words, a string inside its binary:
/// "Uncached input is expensive, and often happens when sending a message to a
/// session that has gone idle. /compact before stepping away keeps the
/// cold-start small."
///
/// That is a cost you avoid by knowing about it a minute early, and the notch is
/// already the thing watching idle sessions. Everything here exists to answer
/// two questions: is this session about to go cold, and what will it cost to
/// wake it.
struct PromptCacheState: Equatable {
    /// nil when Claude Code has not reported yet, which is every session until
    /// its first API response. Distinct from `false`, which means genuinely
    /// cold and is the state worth acting on.
    var warm: Bool?
    /// When the cache lapses. Unix epoch seconds on the wire.
    var expiresAt: Date?
    /// "5m" or "1h", as the CLI writes it.
    var ttl: String = ""
    /// 0...1.
    var hitRatio: Double?
    /// What waking a cold session costs to rebuild.
    var recacheTokens: Int?
    /// Why the cache last missed: "tools_changed" and friends, comma separated
    /// as they arrive from the forwarder.
    var missCauses: String = ""

    /// Nothing reported at all. A session in this state should show nothing
    /// rather than a reassuring "warm".
    var isUnknown: Bool {
        warm == nil && expiresAt == nil && recacheTokens == nil && hitRatio == nil
    }

    /// Seconds until the cache lapses, nil when unknown, 0 once it has.
    func secondsUntilExpiry(now: Date = Date()) -> TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(now))
    }

    /// How long before expiry counts as "about to go cold".
    ///
    /// Two minutes because the action it prompts, /compact or just sending the
    /// next message, takes seconds: warning earlier would nag through the
    /// middle of normal work, and the 5m TTL means a longer window would be
    /// lit for most of the cache's life.
    static let expiringSoonWindow: TimeInterval = 120

    /// Is the cache gone?
    ///
    /// Either the CLI says so outright, or the expiry time has passed. The
    /// second matters because the status line only redraws while something is
    /// happening: a session left alone goes cold without anything reporting it,
    /// so the last known expiry is the only evidence there will be.
    func isCold(now: Date = Date()) -> Bool {
        if warm == false { return true }
        if let s = secondsUntilExpiry(now: now), s <= 0, warm != nil || expiresAt != nil {
            return true
        }
        return false
    }

    /// Warm, but not for much longer. False once it has actually gone.
    func isExpiringSoon(now: Date = Date()) -> Bool {
        guard !isCold(now: now), let s = secondsUntilExpiry(now: now) else { return false }
        return s > 0 && s <= Self.expiringSoonWindow
    }

    /// Is this worth saying anything about at all?
    ///
    /// Only when there is something to do about it AND a number to justify it.
    /// A cold cache with no rebuild cost reported is not news: it says "this
    /// will cost something" without saying how much, which is the kind of
    /// warning people learn to ignore.
    func isWorthReporting(now: Date = Date()) -> Bool {
        guard !isUnknown else { return false }
        guard (recacheTokens ?? 0) > 0 else { return false }
        return isCold(now: now) || isExpiringSoon(now: now)
    }
}
