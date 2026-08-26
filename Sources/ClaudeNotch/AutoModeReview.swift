import Foundation

// How much ran without anyone being asked.
//
// Since 14 August 2026 auto mode is the default permission mode on Pro, Max and
// Team. A classifier reviews each action instead of the user, and it is
// genuinely better at this than people are: in Anthropic's own test, a
// deliberately dangerous command was caught 89% of the time by the classifier
// and 13.6% of the time by the humans it replaced. Arguing with that would be
// silly.
//
// The part worth surfacing is the remainder. Anthropic also publishes a 17%
// false-negative rate on genuinely overeager actions, described as the
// classifier finding approval-shaped evidence without checking the blast radius
// of what it is approving. Nothing tells you which actions those were, or even
// how many actions went by.
//
// This app's job changes shape accordingly. It used to be the thing that asked
// you. In auto mode it is the thing that can tell you what already happened,
// which matters because PreToolUse hooks run BEFORE the permission system, so
// the notch still sees every tool call even when nothing is ever prompted.
//
// Pure and nonisolated: a mode name and a count.
enum AutoModeReview {

    /// Modes that run tool calls without asking the user.
    ///
    /// Listed explicitly rather than inferred by excluding the asking ones. An
    /// unrecognised mode produces no card, which is the safe direction: a mode
    /// this app has not been taught might well prompt normally, and announcing
    /// that nobody was asked when they were is worse than saying nothing.
    static let nonAskingModes: Set<String> = [
        "auto", "acceptedits", "bypasspermissions", "plan",
    ]

    /// Modes where the user is still asked, kept so the two lists can be
    /// checked against each other in tests.
    static let askingModes: Set<String> = ["default", "ask"]

    nonisolated static func runsWithoutAsking(_ mode: String) -> Bool {
        nonAskingModes.contains(mode.lowercased().replacingOccurrences(of: "_", with: ""))
    }

    /// How many unreviewed actions before it is worth a summary.
    ///
    /// High, because this is a fact about a working session rather than a
    /// problem, and a card at every tenth action would be noise. Fifty is about
    /// a substantial piece of work.
    static let actionsBeforeReview = 50

    nonisolated static func worthReviewing(mode: String, toolCalls: Int, alreadySaid: Bool) -> Bool {
        !alreadySaid && runsWithoutAsking(mode) && toolCalls >= actionsBeforeReview
    }

    // MARK: - What it says

    nonisolated static func cardTitle(actions: Int, project: String) -> String {
        String(format: L("%1$d actions ran in %2$@ without asking you",
                         comment: "Card title summarising unprompted actions. %1$d is a count, %2$@ a folder name"),
               actions, project)
    }

    /// States the case for auto mode as well as the gap. A card that only said
    /// the scary half would be arguing against a setting that is, on the
    /// evidence, safer than what it replaced.
    nonisolated static func cardDetail() -> String {
        L("Auto mode checks each one with a classifier, which catches far more than people do. It is not everything: Anthropic puts its miss rate on overeager actions at about one in six. The history drawer has the full list if you want to skim what ran.",
          comment: "Card body explaining what auto mode does and does not catch")
    }
}
