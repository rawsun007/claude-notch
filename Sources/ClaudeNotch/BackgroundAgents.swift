import Foundation

/// Background agents (`claude --bg`, `claude agents`).
///
/// Claude Code runs these in a daemon, detached from any terminal, which is
/// exactly the situation ClaudeNotch exists for: work happening somewhere you are
/// not looking. Their hooks already reach the app, so they show up as sessions —
/// but they look identical to a session you are sitting in front of, and there is
/// nothing to tell you a background agent is even running, let alone what it was
/// asked to do.
///
/// The daemon keeps its roster at `~/.claude/daemon/roster.json`, which is the
/// only place the short id (what `claude attach` takes) and the task intent
/// exist. Reading it is how the notch can name a background agent and offer to
/// attach to it.
struct BackgroundAgent: Identifiable, Equatable {
    /// The short id `claude attach` / `claude stop` take, e.g. "703d48dc".
    let id: String
    let sessionId: String
    let cwd: String
    /// What the agent was asked to do. This is its name, as far as a human is
    /// concerned — a background agent has no other label.
    let intent: String
    let pid: Int32
    let startedAt: Date?

    var project: String { (cwd as NSString).lastPathComponent }
}

enum BackgroundAgentReader {

    static let rosterPath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/daemon/roster.json")
    }()

    /// Parse the daemon roster. Pure, so the shape of the file can be pinned in a
    /// test rather than discovered in production.
    ///
    /// A worker whose process is gone is dropped: the daemon can leave a stale
    /// entry behind (a crash, a machine that slept), and an agent listed as
    /// running when it is not is worse than not listing it, because the whole
    /// point of the row is to tell you something is still working.
    static func parse(_ data: Data, isAlive: (Int32) -> Bool = processIsAlive) -> [BackgroundAgent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workers = root["workers"] as? [String: Any]
        else { return [] }

        var agents: [BackgroundAgent] = []
        for (short, raw) in workers {
            guard let w = raw as? [String: Any] else { continue }
            let sessionId = (w["sessionId"] as? String) ?? ""
            let cwd = (w["cwd"] as? String) ?? ""
            let pid = Int32((w["pid"] as? Int) ?? 0)
            guard pid > 0, isAlive(pid) else { continue }

            let dispatch = (w["dispatch"] as? [String: Any]) ?? [:]
            let seed = (dispatch["seed"] as? [String: Any]) ?? [:]
            let intent = (seed["intent"] as? String)
                ?? (dispatch["short"] as? String)
                ?? short

            let startedAt = (w["startedAt"] as? Double).map {
                Date(timeIntervalSince1970: $0 / 1000)   // the daemon writes milliseconds
            }

            agents.append(BackgroundAgent(id: short, sessionId: sessionId, cwd: cwd,
                                          intent: intent, pid: pid, startedAt: startedAt))
        }
        // Newest first, and stable when two start in the same millisecond.
        return agents.sorted {
            let a = $0.startedAt ?? .distantPast
            let b = $1.startedAt ?? .distantPast
            return a != b ? a > b : $0.id < $1.id
        }
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        // Signal 0 tests for existence without touching the process.
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func read() -> [BackgroundAgent] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: rosterPath)) else { return [] }
        return parse(data)
    }

    /// The command that opens a background agent in a terminal.
    static func attachCommand(_ agent: BackgroundAgent) -> String {
        "claude attach \(agent.id)"
    }
}
