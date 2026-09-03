import Foundation

// A session changed model mid-run (the `PostModelSwitch` hook, Claude Code
// 2.1.251+).
//
// Before this, the notch learned about a model change only when some later hook
// happened to carry a model id, which could be several tool calls away or not
// until the next status line. Until then the session list showed the old model,
// and the cost meter attributed spend to it. This is the CLI saying it outright.
//
// Worth a card, not just a quieter field update, because the model is what the
// cost and the context window are read against: a session that moved from opus
// to sonnet is spending differently from the number you last looked at, and one
// that moved the other way is spending a lot more.

extension AppState {

    /// How long the same destination model counts as the same switch.
    ///
    /// Both hooks fire per session, and a `/model` change in one terminal can be
    /// reported by more than one path in quick succession. Short, because a real
    /// second switch back and forth is news.
    nonisolated static let modelSwitchCardGrace: TimeInterval = 5

    /// Rough cost order of the model families: haiku < sonnet < opus.
    ///
    /// Zero means "not a family we know", which is not the same as cheap. Every
    /// caller has to treat 0 as unknown and decline to act, because the whole
    /// point of the ordering is deciding whether a switch costs more, and a
    /// model we cannot place tells us nothing about that.
    ///
    /// Version is deliberately not part of the order. Anthropic prices by
    /// family, and sonnet 4.6 is not more expensive than sonnet 4.5, so
    /// treating a version bump as an upgrade would gate switches that cost
    /// nothing extra and teach people to turn the gate off.
    nonisolated static func modelCostRank(_ model: String) -> Int {
        let m = model.lowercased()
        if m.contains("haiku")  { return 1 }
        if m.contains("sonnet") { return 2 }
        if m.contains("opus")   { return 3 }
        return 0
    }

    /// Is this switch a move to a more expensive family?
    ///
    /// False whenever we cannot tell, which covers an empty `from_model` (the
    /// CLI does not always know what it is switching away from) and any id
    /// outside the three families. That direction is chosen on purpose: this
    /// answer gates a blocking card, so being wrong the other way would stop a
    /// session on a switch nobody asked to be asked about, with the terminal
    /// waiting on a notch the user may not be looking at.
    nonisolated static func modelSwitchIsUpgrade(from: String, to: String) -> Bool {
        let a = modelCostRank(from)
        let b = modelCostRank(to)
        guard a > 0, b > 0 else { return false }
        return b > a
    }

    /// One line for the card: "opus 5 to sonnet 4.6".
    ///
    /// Falls back to the raw ids when a model is not one of the families we
    /// know, rather than showing an empty side. A future model id should read
    /// oddly here, not silently become a blank.
    nonisolated static func modelSwitchDetail(from: String, to: String) -> String {
        let a = ClaudeUsageReader.shortModel(from)
        let b = ClaudeUsageReader.shortModel(to)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return String(format: L("%1$@ to %2$@", comment: "Card detail for a model switch. %1$@ is the old model, %2$@ is the new one"), a, b)
    }

    /// A session switched model. `from` may be empty when the CLI does not know
    /// what it was switching away from; `to` is what the session runs now.
    func noteModelSwitched(sessionId: String, cwd: String, from: String, to: String) {
        // Nothing useful to record without a destination, and a switch to the
        // model already running is not a switch. The CLI reports both, since the
        // hook fires on the attempt rather than on a change actually happening.
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to != from else { return }

        // The field update happens whether or not a card does. The session list
        // and the cost meter should be right even for a switch too rapid to be
        // worth announcing.
        upsertSession(id: sessionId, cwd: cwd) { session in
            session.model = to
        }

        let detail = Self.modelSwitchDetail(from: from, to: to)
        let title = L("Model switched", comment: "Card title: the session changed model mid-run")

        // History is written here ONLY for the switch that gets no card.
        // enqueuePermission logs notification cards itself, so appending before
        // calling it files the same switch twice, which is what the first
        // version of this did: one POST, two identical rows in the activity log.
        if let last = lastModelSwitch[sessionId], last.to == to,
           Date().timeIntervalSince(last.at) < Self.modelSwitchCardGrace {
            appendHistory(HistoryEntry(
                timestamp: Date(),
                kind: .notification,
                toolName: "PostModelSwitch",
                title: title,
                detail: detail,
                project: (cwd as NSString).lastPathComponent,
                outcome: .info))
            return
        }
        lastModelSwitch[sessionId] = (to: to, at: Date())

        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: title,
            detail: detail,
            toolName: "PostModelSwitch",
            source: "Claude Code",
            cwd: cwd,
            resolver: { _, _ in }))
    }
}
