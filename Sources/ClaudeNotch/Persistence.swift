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
        var persistentNotchDisplay: Bool? = nil
        var lastDigestDate: String? = nil
        var sessionCostCap: Double? = nil
        var dailyCostCap: Double? = nil
        var fiveHourCostCap: Double? = nil
        var weeklyCostCap: Double? = nil
        var requireTouchID: Bool? = nil
        var mirrorToNotificationCenter: Bool? = nil
        var enforceBudget: Bool? = nil
        var statusBarItems: [String]? = nil
        var contextWindowMode: String? = nil
        var notchTitleMode: String? = nil
        var customNotchTitle: String? = nil
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
            persistentNotchDisplay: try? c.decode(Bool.self, forKey: .persistentNotchDisplay),
            lastDigestDate: try? c.decode(String.self, forKey: .lastDigestDate),
            sessionCostCap: try? c.decode(Double.self, forKey: .sessionCostCap),
            dailyCostCap: try? c.decode(Double.self, forKey: .dailyCostCap),
            fiveHourCostCap: try? c.decode(Double.self, forKey: .fiveHourCostCap),
            weeklyCostCap: try? c.decode(Double.self, forKey: .weeklyCostCap),
            requireTouchID: try? c.decode(Bool.self, forKey: .requireTouchID),
            mirrorToNotificationCenter: try? c.decode(Bool.self, forKey: .mirrorToNotificationCenter),
            enforceBudget: try? c.decode(Bool.self, forKey: .enforceBudget),
            statusBarItems: try? c.decode([String].self, forKey: .statusBarItems),
            contextWindowMode: try? c.decode(String.self, forKey: .contextWindowMode),
            notchTitleMode: try? c.decode(String.self, forKey: .notchTitleMode),
            customNotchTitle: try? c.decode(String.self, forKey: .customNotchTitle)
        )
    }
}
