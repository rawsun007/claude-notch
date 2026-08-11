import Foundation

/// What plan you are on, and what it has left.
///
/// The status line gives two percentages and their reset times, which is enough
/// to draw a bar and no more: it does not say which plan those limits belong to,
/// whether usage credits are switched on, or what has been spent on them. Claude
/// Code keeps all of that in ~/.claude.json, refreshed whenever it talks to the
/// API, so it can be read locally instead of asked for over the network.
///
/// This is a cache belonging to another program. Every field is optional and
/// every shape is checked, because a key that changes name upstream must show up
/// as a missing row rather than a crash. Nothing here writes to the file.
enum PlanReader {

    // MARK: - Model

    struct Account: Equatable {
        var tier: String            // "Pro", "Max 20x", "Team"…
        var rawTier: String         // organization_type as written, for the tooltip
        var email: String? = nil          // which login this is, for people with several
        var displayName: String? = nil
        var organization: String? = nil   // nil when it is only the email restated
        var billing: String? = nil        // "Subscription", "Invoice"…
        var role: String? = nil           // "admin", "member"
        var seat: String? = nil           // seat tier on Team/Enterprise plans
        var memberSince: Date? = nil
        var trialEndsAt: Date? = nil
    }

    /// One rate-limit window. `kind` is Claude Code's own name for it, which is
    /// the thing that varies by plan: a Max plan reports Opus separately.
    struct Limit: Equatable {
        var kind: String
        var label: String
        var percent: Double         // 0...100
        var severity: String        // "normal", "warning"…
        var resetsAt: Date?
        var isActive: Bool
    }

    /// Usage credits: the pay-as-you-go pool that covers you past the plan
    /// limits. Off for most people, and off in a few different ways, so the
    /// reason matters as much as the numbers.
    struct Credits: Equatable {
        var isEnabled: Bool
        var everEnabled: Bool
        var userDisabled: Bool
        var spendLimitReached: Bool
        var canPurchase: Bool
        var disabledReason: String?
        var usedCredits: Double?
        var monthlyLimit: Double?
        var utilization: Double?    // 0...100 of the monthly limit
        var currency: String?
        /// Spent this period and the cap, already converted out of minor units.
        var spent: Double?
        var spendLimit: Double?
        var balance: Double?
        var autoReload: Bool?
        /// Claude Code's own word for how close this is to the cap: "normal",
        /// "warning", "critical". Shown rather than re-derived from the
        /// percentage, so the notch and the CLI never disagree about severity.
        var severity: String? = nil
    }

    struct Snapshot: Equatable {
        var account: Account?
        var limits: [Limit]
        var credits: Credits?
        /// When Claude Code last refreshed the numbers, not when we read them.
        var fetchedAt: Date?

        var isEmpty: Bool { account == nil && limits.isEmpty && credits == nil }
    }

    // MARK: - Reading

    static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    /// Read and parse, or nil when the file is absent or unreadable. The file is
    /// well over 100 KB of unrelated state, so this is called on demand (opening
    /// the page, and on a slow timer while it is open) rather than polled.
    static func load(path: String? = nil) -> Snapshot? {
        let p = path ?? configPath
        guard let data = FileManager.default.contents(atPath: p) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Snapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let account = parseAccount(root["oauthAccount"] as? [String: Any])
        let cache = root["cachedUsageUtilization"] as? [String: Any]
        let util = cache?["utilization"] as? [String: Any]
        let snapshot = Snapshot(
            account: account,
            limits: parseLimits(util),
            credits: parseCredits(util),
            fetchedAt: (cache?["fetchedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    // MARK: - Pieces

    static func parseAccount(_ o: [String: Any]?) -> Account? {
        guard let o else { return nil }
        let raw = (o["organizationType"] as? String) ?? ""
        guard !raw.isEmpty else { return nil }
        let email = (o["emailAddress"] as? String)?.nilIfEmpty
        return Account(
            tier: tierName(raw),
            rawTier: raw,
            email: email,
            displayName: (o["displayName"] as? String)?.nilIfEmpty,
            organization: organizationName(o["organizationName"] as? String, email: email),
            billing: (o["billingType"] as? String).map(billingName),
            role: (o["organizationRole"] as? String)?.nilIfEmpty,
            seat: (o["seatTier"] as? String)?.nilIfEmpty,
            memberSince: date(o["subscriptionCreatedAt"]) ?? date(o["accountCreatedAt"]),
            trialEndsAt: date(o["claudeCodeTrialEndsAt"])
        )
    }

    /// `limits` is the list Claude Code itself renders, so it already reflects
    /// whatever windows this plan has. The two named objects are the fallback
    /// for a cache written before that list existed.
    static func parseLimits(_ util: [String: Any]?) -> [Limit] {
        guard let util else { return [] }
        if let rows = util["limits"] as? [[String: Any]], !rows.isEmpty {
            return rows.compactMap { row in
                guard let kind = row["kind"] as? String, let pct = number(row["percent"]) else { return nil }
                return Limit(kind: kind,
                             label: limitName(kind),
                             percent: clampPercent(pct),
                             severity: (row["severity"] as? String) ?? "normal",
                             resetsAt: date(row["resets_at"]),
                             isActive: (row["is_active"] as? Bool) ?? true)
            }
        }
        return ["five_hour", "seven_day"].compactMap { key in
            guard let o = util[key] as? [String: Any], let pct = number(o["utilization"]) else { return nil }
            return Limit(kind: key,
                         label: limitName(key),
                         percent: clampPercent(pct),
                         severity: "normal",
                         resetsAt: date(o["resets_at"]),
                         isActive: true)
        }
    }

    static func parseCredits(_ util: [String: Any]?) -> Credits? {
        guard let util else { return nil }
        let extra = util["extra_usage"] as? [String: Any]
        let spend = util["spend"] as? [String: Any]
        guard extra != nil || spend != nil else { return nil }
        return Credits(
            isEnabled: (extra?["is_enabled"] as? Bool) ?? (spend?["enabled"] as? Bool) ?? false,
            everEnabled: (extra?["credits_ever_enabled"] as? Bool) ?? false,
            userDisabled: (extra?["user_disabled"] as? Bool) ?? false,
            spendLimitReached: (extra?["spend_limit_reached"] as? Bool) ?? false,
            canPurchase: (spend?["can_purchase_credits"] as? Bool) ?? false,
            disabledReason: ((extra?["disabled_reason"] as? String) ?? (spend?["disabled_reason"] as? String))?.nilIfEmpty,
            usedCredits: number(extra?["used_credits"]),
            monthlyLimit: number(extra?["monthly_limit"]),
            // `spend.percent` is the figure Claude Code itself renders, so it
            // wins over one derived from extra_usage. The two disagree in the
            // ordinary case (33 vs 32.55) because they round differently, and
            // showing a number that does not match the CLI invites the
            // reasonable conclusion that one of them is wrong.
            utilization: (number(spend?["percent"]) ?? number(extra?["utilization"])).map(clampPercent),
            currency: (extra?["currency"] as? String) ?? (money(spend?["used"])?.currency),
            spent: money(spend?["used"])?.amount,
            spendLimit: money(spend?["limit"])?.amount ?? capAmount(spend?["cap"]),
            balance: money(spend?["balance"])?.amount,
            autoReload: spend?["auto_reload"] as? Bool,
            severity: (spend?["severity"] as? String)?.nilIfEmpty
        )
    }

    /// The cap, whichever currency it is expressed in.
    ///
    /// `cap` is not a money object. It is a container of them —
    /// `{"money": null, "credits": {amount_minor, exponent}}` — so reading it
    /// as one always came back nil and the fallback never fired. It only went
    /// unnoticed because `spend.limit` is normally present too.
    ///
    /// A credits cap carries no `currency` of its own, so the surrounding
    /// `spend.used.currency` names it.
    static func capAmount(_ cap: Any?) -> Double? {
        guard let cap = cap as? [String: Any] else { return nil }
        return money(cap["money"])?.amount ?? money(cap["credits"])?.amount
    }

    // MARK: - Naming

    /// Plan names are matched loosely on purpose. A new tier upstream should
    /// read as "Max 50x" rather than vanish, so anything unrecognised is
    /// prettified instead of dropped.
    static func tierName(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("enterprise") { return "Enterprise" }
        if s.contains("team")       { return "Team" }
        if s.contains("max") {
            // The multiplier component, "20x". Matched on a leading digit as
            // well as the trailing x, because "max" itself ends in one.
            let multiplier = s.split(separator: "_").first {
                $0.hasSuffix("x") && ($0.first?.isNumber ?? false)
            }
            return multiplier.map { "Max \($0)" } ?? "Max"
        }
        if s.contains("pro")        { return "Pro" }
        if s.contains("free")       { return "Free" }
        return raw.replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// A personal account's organization is named after the email that owns it,
    /// "you@example.com's Organization", which says nothing the email row above
    /// it does not. Dropped, so the row only appears for a real team.
    static func organizationName(_ raw: String?, email: String?) -> String? {
        guard let name = raw?.nilIfEmpty else { return nil }
        if let email, name.localizedCaseInsensitiveContains(email) { return nil }
        return name
    }

    static func billingName(_ raw: String) -> String {
        switch raw.lowercased() {
        case let s where s.contains("stripe"):  return "Subscription"
        case let s where s.contains("invoice"): return "Invoiced"
        case let s where s.contains("api"):     return "API billing"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func limitName(_ kind: String) -> String {
        switch kind {
        case "session", "five_hour":     return "5-hour session"
        case "weekly_all", "seven_day":  return "Weekly, all models"
        case "weekly_opus":              return "Weekly, Opus"
        case "weekly_sonnet":            return "Weekly, Sonnet"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Why credits are off, in words. The raw reason is an identifier meant for
    /// Claude Code's own UI, so an unknown one is shown as-is rather than hidden.
    static func disabledReasonText(_ raw: String) -> String {
        switch raw {
        case "org_level_disabled":  return "Turned off for this organization"
        case "user_disabled":       return "You turned it off"
        case "not_eligible":        return "Not available on this plan"
        case "payment_required":    return "Needs a payment method"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - Coercion

    /// Numbers arrive as Int, Double or String depending on which part of the
    /// cache wrote them.
    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func clampPercent(_ d: Double) -> Double { min(100, max(0, d)) }

    /// { amount_minor, currency, exponent } as a plain amount. Minor units and
    /// an exponent, so 1234 with exponent 2 is 12.34 and a zero-decimal currency
    /// has exponent 0.
    static func money(_ v: Any?) -> (amount: Double, currency: String)? {
        guard let o = v as? [String: Any], let minor = number(o["amount_minor"]) else { return nil }
        let exponent = number(o["exponent"]) ?? 2
        return (minor / pow(10, exponent), (o["currency"] as? String) ?? "USD")
    }

    /// ISO 8601 with fractional seconds (what the cache writes), plain ISO 8601,
    /// or epoch seconds.
    static func date(_ v: Any?) -> Date? {
        if let n = number(v), n > 0 { return Date(timeIntervalSince1970: n) }
        guard let s = v as? String, !s.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
