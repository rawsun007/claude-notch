import Foundation

// Noticing when you keep answering the same question.
//
// "Always allow" has been on the card from the start, and almost nobody uses
// it: you are mid-flow, the fastest key is Return, and setting up a rule is a
// small piece of admin you will do later and never do. So the app counts how
// often the same command has been approved by hand and, once that is clearly a
// habit, says so on the card. The button was always there; this is the app
// pointing at it at the one moment the answer is obvious.

extension AppState {
    /// Approvals of the same command before it counts as a habit. Three is the
    /// point where a fourth is a safe bet: twice is a coincidence, and waiting
    /// for five means the suggestion arrives long after the annoyance did.
    static let ruleSuggestionThreshold = 3

    /// What a would-be rule for this request is keyed on: the same identity an
    /// exact-command AllowRule would have, so the count follows the rule the
    /// user would actually create.
    nonisolated static func approvalKey(tool: String, detail: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: detail)
        return AllowRule(tool: tool, commandRegex: "^\(escaped)$").id
    }

    /// Count one manual approval. Only manual ones: an auto-approved call is
    /// already covered by a rule, and counting it would suggest a rule for the
    /// rule that just fired.
    func noteManualApproval(_ req: PermissionRequest) {
        guard req.kind == .toolUse, req.source != "Demo" else { return }
        // A dangerous command is exactly the thing that should keep asking.
        guard !req.isDangerous else { return }

        let key = Self.approvalKey(tool: req.toolName, detail: req.detail)
        repeatApprovals[key, default: 0] += 1

        // Keep the map from growing forever: one entry per distinct command
        // seen, and a busy machine sees a lot of distinct commands. Drop the
        // ones that never became a habit, since those are what the cap is full
        // of, and a genuine repeat will climb back within a few approvals.
        if repeatApprovals.count > Self.repeatApprovalsCap {
            repeatApprovals = repeatApprovals.filter { $0.value > 1 }
        }
        schedulePersist()
    }

    /// How many times this exact command has been approved by hand.
    func approvalCount(for req: PermissionRequest) -> Int {
        repeatApprovals[Self.approvalKey(tool: req.toolName, detail: req.detail)] ?? 0
    }

    /// Whether to point at "Always allow" on this card.
    ///
    /// Never for a dangerous command, and never when a rule already covers it,
    /// which would be the app suggesting something it has already done.
    func suggestsRule(for req: PermissionRequest) -> Bool {
        guard req.kind == .toolUse, !req.isDangerous else { return false }
        guard !allowRules.contains(where: { $0.matches(req) }) else { return false }
        return approvalCount(for: req) >= Self.ruleSuggestionThreshold
    }

    /// Once a rule exists, the tally behind it is spent: keep counting and the
    /// suggestion would come back the moment the user deleted the rule, which
    /// reads as the app arguing with them.
    func clearApprovalCount(for req: PermissionRequest) {
        repeatApprovals.removeValue(forKey: Self.approvalKey(tool: req.toolName, detail: req.detail))
    }
}
