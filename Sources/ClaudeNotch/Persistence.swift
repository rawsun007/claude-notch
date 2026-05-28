import Foundation

/// File-backed snapshot of the parts of AppState that should survive
/// quit/relaunch. Lives at `~/.claudenotch/state.json`, written atomically
/// after debounced bursts of mutations (see AppState.schedulePersist).
enum Persistence {
    struct Snapshot: Codable {
        var history: [HistoryEntry]
        var allowRules: Set<AllowRule>
        var recentProjects: [String]
        var autoApprove: Bool? = nil
        var soundMuted: Bool? = nil
        var stats: UsageStats? = nil
        var alertSound: String? = nil
        var perToolSounds: Bool? = nil
        var lastDigestDate: String? = nil
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
            allowRules: (try? c.decode(Set<AllowRule>.self, forKey: .allowRules)) ?? [],
            recentProjects: (try? c.decode([String].self, forKey: .recentProjects)) ?? [],
            autoApprove: try? c.decode(Bool.self, forKey: .autoApprove),
            soundMuted: try? c.decode(Bool.self, forKey: .soundMuted),
            stats: try? c.decode(UsageStats.self, forKey: .stats),
            alertSound: try? c.decode(String.self, forKey: .alertSound),
            perToolSounds: try? c.decode(Bool.self, forKey: .perToolSounds),
            lastDigestDate: try? c.decode(String.self, forKey: .lastDigestDate)
        )
    }
}
