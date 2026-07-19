import Foundation

/// File-backed snapshot of the parts of AppState that should survive
/// quit/relaunch. Lives at `~/.claudenotch/state.json`, written atomically
/// after debounced bursts of mutations (see AppState.schedulePersist).
enum Persistence {
    struct Snapshot: Codable {
        var history: [HistoryEntry]
        var sessionHistory: [SessionRecord]? = nil
        var allowRules: Set<AllowRule>
        var recentProjects: [String]
        var autoApprove: Bool? = nil
        var soundMuted: Bool? = nil
        var stats: UsageStats? = nil
        var alertSound: String? = nil
        var perToolSounds: Bool? = nil
        var perToolSoundMap: [String: String]? = nil
        var persistentNotchDisplay: Bool? = nil
        var petEnabled: Bool? = nil
        var lastDigestDate: String? = nil
        var lastUpdateCardVersion: String? = nil
        var lastSeenVersion: String? = nil
        var sessionCostCap: Double? = nil
        var dailyCostCap: Double? = nil
        var fiveHourCostCap: Double? = nil
        var weeklyCostCap: Double? = nil
        var requireTouchID: Bool? = nil
        var mirrorToNotificationCenter: Bool? = nil
        var completionNotificationsEnabled: Bool? = nil
        var digestNotificationsEnabled: Bool? = nil
        var hideFromScreenCapture: Bool? = nil
        var showSpendInMenuBar: Bool? = nil
        var enforceBudget: Bool? = nil
        var statusBarItems: [String]? = nil
        var contextWindowMode: String? = nil
        var notchTitleMode: String? = nil
        var customNotchTitle: String? = nil
        /// Context windows Claude Code reported, keyed by model id. Real data, not
        /// a guess — see AppState.noteStatusLine.
        var learnedContextWindows: [String: Int]? = nil
        /// The last plan-limit reading Claude Code gave us, and when. Persisted so
        /// a relaunch does not blank the limits (they only arrive while a session
        /// is redrawing its status line, which can be hours away).
        var fiveHourLimitPercent: Double? = nil
        var weeklyLimitPercent: Double? = nil
        var fiveHourResetAt: Date? = nil
        var weeklyResetAt: Date? = nil
        var limitsUpdatedAt: Date? = nil
        var breakRemindersEnabled: Bool? = nil
        var longRunAlertsEnabled: Bool? = nil
        var rateLimitWarningsEnabled: Bool? = nil
        /// Project directories the user pinned to the top of the sessions list.
        var pinnedProjects: [String]? = nil
    }

    static let storeURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudenotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    /// Load the persisted snapshot, or nil on first launch / parse failure.
    /// A failed read is silent — we'd rather start fresh than crash.
    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// Decode each field independently so a single unreadable section (e.g. a
// history schema change) degrades gracefully instead of throwing away the
// whole snapshot — which previously dropped all usage stats on every update
// that added a field. Defined in an extension to keep the memberwise init that
// persistNow() uses.
extension Persistence.Snapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            history: (try? c.decode([HistoryEntry].self, forKey: .history)) ?? [],
            sessionHistory: try? c.decode([SessionRecord].self, forKey: .sessionHistory),
            allowRules: (try? c.decode(Set<AllowRule>.self, forKey: .allowRules)) ?? [],
            recentProjects: (try? c.decode([String].self, forKey: .recentProjects)) ?? [],
            autoApprove: try? c.decode(Bool.self, forKey: .autoApprove),
            soundMuted: try? c.decode(Bool.self, forKey: .soundMuted),
            stats: try? c.decode(UsageStats.self, forKey: .stats),
            alertSound: try? c.decode(String.self, forKey: .alertSound),
            perToolSounds: try? c.decode(Bool.self, forKey: .perToolSounds),
            perToolSoundMap: try? c.decode([String: String].self, forKey: .perToolSoundMap),
            persistentNotchDisplay: try? c.decode(Bool.self, forKey: .persistentNotchDisplay),
            petEnabled: try? c.decode(Bool.self, forKey: .petEnabled),
            lastDigestDate: try? c.decode(String.self, forKey: .lastDigestDate),
            lastUpdateCardVersion: try? c.decode(String.self, forKey: .lastUpdateCardVersion),
            lastSeenVersion: try? c.decode(String.self, forKey: .lastSeenVersion),
            sessionCostCap: try? c.decode(Double.self, forKey: .sessionCostCap),
            dailyCostCap: try? c.decode(Double.self, forKey: .dailyCostCap),
            fiveHourCostCap: try? c.decode(Double.self, forKey: .fiveHourCostCap),
            weeklyCostCap: try? c.decode(Double.self, forKey: .weeklyCostCap),
            requireTouchID: try? c.decode(Bool.self, forKey: .requireTouchID),
            mirrorToNotificationCenter: try? c.decode(Bool.self, forKey: .mirrorToNotificationCenter),
            completionNotificationsEnabled: try? c.decode(Bool.self, forKey: .completionNotificationsEnabled),
            digestNotificationsEnabled: try? c.decode(Bool.self, forKey: .digestNotificationsEnabled),
            hideFromScreenCapture: try? c.decode(Bool.self, forKey: .hideFromScreenCapture),
            showSpendInMenuBar: try? c.decode(Bool.self, forKey: .showSpendInMenuBar),
            enforceBudget: try? c.decode(Bool.self, forKey: .enforceBudget),
            statusBarItems: try? c.decode([String].self, forKey: .statusBarItems),
            contextWindowMode: try? c.decode(String.self, forKey: .contextWindowMode),
            notchTitleMode: try? c.decode(String.self, forKey: .notchTitleMode),
            customNotchTitle: try? c.decode(String.self, forKey: .customNotchTitle),
            learnedContextWindows: try? c.decode([String: Int].self, forKey: .learnedContextWindows),
            fiveHourLimitPercent: try? c.decode(Double.self, forKey: .fiveHourLimitPercent),
            weeklyLimitPercent: try? c.decode(Double.self, forKey: .weeklyLimitPercent),
            fiveHourResetAt: try? c.decode(Date.self, forKey: .fiveHourResetAt),
            weeklyResetAt: try? c.decode(Date.self, forKey: .weeklyResetAt),
            limitsUpdatedAt: try? c.decode(Date.self, forKey: .limitsUpdatedAt),
            breakRemindersEnabled: try? c.decode(Bool.self, forKey: .breakRemindersEnabled),
            longRunAlertsEnabled: try? c.decode(Bool.self, forKey: .longRunAlertsEnabled),
            rateLimitWarningsEnabled: try? c.decode(Bool.self, forKey: .rateLimitWarningsEnabled),
            pinnedProjects: try? c.decode([String].self, forKey: .pinnedProjects)
        )
    }
}
