import Foundation

// Named agents in a session's team, and which of them is waiting on you.
//
// Claude Code grew a teammate system: named persistent agents, each in its own
// tmux pane, with a roster, a mailbox, and messages between them. They are not
// subagents. A subagent returns into the conversation that spawned it; a
// teammate sits in a pane of its own and can be idle for twenty minutes without
// anything on screen saying so.
//
// This is the same problem the notch already exists for, one level out. The
// most-repeated complaint about running several sessions is "one of them is
// usually sitting on a permission prompt I never saw", and a team of teammates
// multiplies exactly that: more panes, same single pair of eyes, and tmux does
// not report agent status.
//
// `TeammateIdle` is the CLI telling us which named teammate has stopped. That
// is precisely the card the notch already renders for sessions, so this file is
// only the naming and the wording.
//
// Pure and nonisolated: the payload is untrusted text off a hook and the
// sanitizing belongs in tests.
enum Teammate {

    /// Longest teammate name kept.
    ///
    /// The name is payload-supplied and lands in a card title, so it is bounded
    /// here rather than trusted. Names are chosen by whoever spawned the
    /// teammate and are short in practice; this only stops a hostile or
    /// malformed one from becoming the whole notch.
    static let nameLimit = 40

    /// A teammate name fit to display, or empty if there isn't one.
    ///
    /// Control characters are stripped rather than escaped: a newline in a card
    /// title breaks the layout, and no legitimate name contains one.
    nonisolated static func displayName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.count <= nameLimit
            ? cleaned
            : String(cleaned.prefix(nameLimit - 1)) + "\u{2026}"
    }

    // MARK: - What it says

    nonisolated static func cardTitle(name: String) -> String {
        guard !name.isEmpty else {
            return L("A teammate is waiting on you",
                     comment: "Card title when an unnamed teammate agent has gone idle")
        }
        return String(format: L("%@ is waiting on you",
                                comment: "Card title when a named teammate agent has gone idle. %@ is the teammate's name"),
                      name)
    }

    nonisolated static func cardDetail(project: String) -> String {
        let what = L("It has stopped and is idle in its own pane.",
                     comment: "Card body explaining that a teammate agent is idle in a separate terminal pane")
        guard !project.isEmpty else { return what }
        return what + " " + String(format: L("Working in %@.",
                                             comment: "Card body naming the project a teammate is working in. %@ is a folder name"),
                                   project)
    }
}
