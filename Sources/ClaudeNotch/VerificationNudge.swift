import Foundation

// A turn that changed code and never checked it.
//
// The most repeated piece of advice about running these agents is also the
// dullest: give it a check it can run. Claude stops when the work *looks* done,
// and without something that can fail, "looks done" is the only signal there
// is. A session that edits nine files and runs nothing is not finished, it is
// unverified, and the two are indistinguishable from the outside.
//
// This is not the same question `CompletionAudit` asks. That one catches a
// claim contradicted by evidence: "tests pass" when a test command just failed.
// This one catches the absence of evidence, which is the more common case and
// the quieter one, because there is nothing to contradict.
//
// Pure and nonisolated: the whole of it is classifying a command and comparing
// two counts, and both belong in tests.
enum VerificationNudge {

    /// How many edited files before silence is worth mentioning.
    ///
    /// Three, not one. A one-file change with an obvious diff is exactly the
    /// case where running the suite is overkill, and a nudge there is the kind
    /// that teaches people to ignore nudges.
    static let editsBeforeAdvising = 3

    /// Tools that change code on disk.
    nonisolated static func isEdit(tool: String) -> Bool {
        ["Write", "Edit", "NotebookEdit"].contains(tool)
    }

    /// Whether a tool call is the session checking its own work.
    ///
    /// Tests count, and so does anything that fails on a broken tree: a build,
    /// a type check, a linter. They are not equally strong, but they are all
    /// something that can say no, which is the property that matters. Reuses
    /// `CompletionAudit.isTestCommand` for the test half rather than keeping a
    /// second list that will drift from it.
    nonisolated static func isVerification(tool: String, input: [String: Any]) -> Bool {
        guard tool == "Bash", let raw = input["command"] as? String else { return false }
        let command = raw.lowercased()
        if CompletionAudit.isTestCommand(raw) { return true }
        return buildMarkers.contains { command.contains($0) }
    }

    /// Commands that fail when the tree is broken. Substring matched, because
    /// they arrive inside real command lines with flags and paths around them.
    static let buildMarkers: [String] = [
        "swift build", "xcodebuild", "npm run build", "yarn build", "pnpm build",
        "make ", "cargo build", "cargo check", "go build", "go vet",
        "tsc", "mypy", "eslint", "ruff", "clippy", "gradle", "mvn ",
    ]

    /// Whether to say anything.
    ///
    /// Only when a session both changed a meaningful amount and never ran
    /// anything that could have failed.
    nonisolated static func worthAdvising(edits: Int, verified: Bool) -> Bool {
        !verified && edits >= editsBeforeAdvising
    }

    // MARK: - What it says

    nonisolated static func cardTitle(edits: Int) -> String {
        String(format: L("This session changed %d files and ran no check",
                         comment: "Card title when a session edited files without running tests or a build. %d is a file count"),
               edits)
    }

    nonisolated static func cardDetail() -> String {
        L("No tests, no build, nothing that could have failed. An agent stops when the work looks done, so without a check it can run, looking done is the only signal it had.",
          comment: "Card body explaining why an unverified session is worth a second look")
    }
}
