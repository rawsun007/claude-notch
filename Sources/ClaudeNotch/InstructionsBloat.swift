import Foundation

// A CLAUDE.md long enough that the agent stops reading it properly.
//
// The advice everyone repeats, Anthropic included, is that a bloated
// instruction file makes Claude ignore the rules that matter, and that
// emphasising many lines means none of them stands out. Both are checkable
// without understanding a word of the content: one is a length, the other is a
// count of shouting.
//
// `ProjectInstructions` already answers whether a project has instructions and
// whether they are stale. This answers the third way the file goes wrong, and
// it is deliberately a separate type so that adding it cannot change what the
// existing two report.
//
// Pure and nonisolated: counting lines and matches.
enum InstructionsBloat {

    /// Long enough to be worth pruning.
    ///
    /// Generous. Common guidance says aim for a couple of hundred lines, but
    /// the cost of being wrong here is telling somebody their careful, correct
    /// file is a problem, so the bar sits well above the recommendation rather
    /// than at it.
    static let longFile = 400

    /// How many emphasised lines before emphasis stops meaning anything.
    ///
    /// One is the recommendation. Three is where this speaks, for the same
    /// reason the length bar is generous.
    static let tooMuchEmphasis = 4

    /// The words people use to mark a line as the important one.
    static let emphasisMarkers = ["IMPORTANT", "CRITICAL", "MUST ", "NEVER ", "ALWAYS "]

    struct Finding: Equatable {
        var lines: Int
        var emphasised: Int
        var isLong: Bool { lines > longFile }
        var isShouty: Bool { emphasised >= tooMuchEmphasis }
        var worthSaying: Bool { isLong || isShouty }
    }

    nonisolated static func inspect(_ text: String) -> Finding {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        // Counted per line, not per occurrence: a line that says IMPORTANT
        // twice is still one emphasised line, and counting it twice would make
        // a single shouted rule look like two.
        let emphasised = text.split(separator: "\n").filter { line in
            emphasisMarkers.contains { line.contains($0) }
        }.count
        return Finding(lines: lines, emphasised: emphasised)
    }

    nonisolated static func read(path: String) -> Finding? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return inspect(text)
    }

    // MARK: - What it says

    nonisolated static func cardTitle(_ f: Finding) -> String {
        f.isLong
            ? String(format: L("This project's CLAUDE.md is %d lines",
                               comment: "Card title when the instruction file is long. %d is a line count"),
                     f.lines)
            : String(format: L("This project's CLAUDE.md emphasises %d lines",
                               comment: "Card title when too many lines are marked important. %d is a count"),
                     f.emphasised)
    }

    nonisolated static func cardDetail(_ f: Finding) -> String {
        f.isLong
            ? L("A long instruction file gets skimmed, and the rules that matter go with the rest. The test for a line is whether removing it would cause a mistake.",
                comment: "Card body when the instruction file is long")
            : L("If several lines are marked important, none of them stands out. One line can carry the emphasis.",
                comment: "Card body when too many lines are marked important")
    }
}
