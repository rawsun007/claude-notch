import Foundation
import AppKit

// The activity log and the archived session records.

extension AppState {
    /// Every history sink is downstream of this one call: the drawer, the
    /// settings page, `state.json` on disk, and the CSV and JSON exports people
    /// paste into tickets. Redacting here covers all of them, and covers them
    /// at the moment the entry is created rather than at four render sites that
    /// can each be forgotten.
    func appendHistory(_ entry: HistoryEntry) {
        history.insert(entry.redacted(), at: 0)
        if history.count > historyMax {
            history = Array(history.prefix(historyMax))
        }
        schedulePersist()
    }

    /// Whether a finished session is worth a row in the history.
    ///
    /// The old rule ("it ran a tool, or it has a project name") let anything
    /// through, because every hook payload carries a cwd and therefore a project
    /// name. Any single stray hook — a probe, a script, a one-off command in a
    /// scratch directory — became a session in the list, which is why the
    /// history filled up with one-second entries named after folders that no
    /// longer exist.
    ///
    /// A session is a session if Claude actually did something in it: it burned
    /// tokens, it cost money, or it changed a file. Everything else is noise.
    nonisolated static func isWorthArchiving(_ session: LiveSession) -> Bool {
        guard isRealProject(session.cwd) else { return false }
        return session.contextTokens > 0 || session.sessionCostUSD > 0 || !session.touchedFiles.isEmpty
    }

    /// The same rule applied to an already-archived row, so history saved under
    /// the old rule gets swept clean on the next launch. A record has no file
    /// list, so the evidence is tokens or money.
    nonisolated static func isWorthKeeping(_ record: SessionRecord) -> Bool {
        guard isRealProject(record.cwd) else { return false }
        return record.contextTokens > 0 || record.costUSD > 0
    }

    /// Whether a working directory is somebody's project, or just a scratch
    /// directory the machine will delete on its own.
    ///
    /// A one-off run in a temp directory is real work — it burns real tokens and
    /// costs real money, so the "did Claude actually do something" rule keeps it —
    /// but it is not a PROJECT. It shows up in the Projects tab next to the
    /// repository you have spent a fortnight in, and it will not exist tomorrow.
    /// Anything the OS owns (/tmp, /private/tmp, /var/folders) is a scratch space,
    /// not a project.
    nonisolated static func isRealProject(_ cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        let path = (cwd as NSString).standardizingPath
        let scratchRoots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        for root in scratchRoots where path == root || path.hasPrefix(root + "/") {
            return false
        }
        return true
    }

    /// Write (or rewrite) this session's history row.
    ///
    /// This is called at the end of every *turn*, not only at the end of the
    /// session — Stop fires each time Claude finishes replying. The first cut
    /// archived once and then refused to touch the row again, so a session's
    /// record froze the moment its first turn ended: an afternoon of work was
    /// filed as "27s", with the cost and the tool count from that one turn.
    ///
    /// The row is therefore keyed by the session and updated in place. Its start
    /// stays put, its end moves with the latest turn, and the totals track the
    /// live session, so the duration is the whole session and not its first
    /// breath.
    /// One-line human summary of a session for the searchable history: its
    /// /rename title if it set one, else the first sentence of its last reply.
    /// Trimmed to a scannable length. Nil when there's nothing worth showing.
    static func sessionSummary(_ session: LiveSession) -> String? {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(120)) }
        let reply = session.fullResponse.isEmpty ? session.lastResponse : session.fullResponse
        let firstLine = reply
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else { return nil }
        return String(firstLine.prefix(120))
    }

    func archiveSession(_ session: LiveSession) {
        guard Self.isWorthArchiving(session) else { return }
        archivedSessionKeys.insert(session.id)

        if let i = sessionHistory.firstIndex(where: { $0.sessionKey == session.id }) {
            sessionHistory[i].endedAt = Date()
            sessionHistory[i].contextTokens = session.contextTokens
            sessionHistory[i].costUSD = session.sessionCostUSD
            sessionHistory[i].toolCallCount = session.toolCallCount
            sessionHistory[i].model = session.model
            sessionHistory[i].linesAdded = session.linesAdded
            sessionHistory[i].linesRemoved = session.linesRemoved
            // Keep a summary once we have one; a later empty reply shouldn't
            // wipe the title the session already earned.
            if let s = Self.sessionSummary(session) { sessionHistory[i].summary = s }
            sessionHistory[i].filesTouched = session.touchedFiles.count
            if !session.gitBranch.isEmpty { sessionHistory[i].gitBranch = session.gitBranch }
            sessionHistory[i].agent = AgentKind.infer(fromModel: session.model).rawValue
            schedulePersist()
            return
        }

        let record = SessionRecord(
            sessionKey: session.id,
            project: session.project.isEmpty ? "unnamed" : session.project,
            cwd: session.cwd,
            startedAt: session.createdAt,
            endedAt: Date(),
            contextTokens: session.contextTokens,
            costUSD: session.sessionCostUSD,
            toolCallCount: session.toolCallCount,
            model: session.model,
            linesAdded: session.linesAdded,
            linesRemoved: session.linesRemoved,
            summary: Self.sessionSummary(session),
            filesTouched: session.touchedFiles.count,
            gitBranch: session.gitBranch.isEmpty ? nil : session.gitBranch,
            agent: AgentKind.infer(fromModel: session.model).rawValue
        )
        sessionHistory.insert(record, at: 0)
        if sessionHistory.count > sessionHistoryMax {
            sessionHistory = Array(sessionHistory.prefix(sessionHistoryMax))
        }
        schedulePersist()
    }

    func clearSessionHistory() {
        sessionHistory.removeAll()
        archivedSessionKeys.removeAll()
        schedulePersist()
    }
}
