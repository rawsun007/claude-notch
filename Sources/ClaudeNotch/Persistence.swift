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
