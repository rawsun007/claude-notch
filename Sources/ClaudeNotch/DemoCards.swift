import Foundation

/// The sample cards behind the two Demos menus.
///
/// These exist twice on screen, in the menu bar and in Settings > Developer,
/// and they used to exist twice in the source as well: the same command
/// strings, diffs and titles, written out in both places. They had already
/// drifted, with the completion-audit demos reachable only from Settings, and
/// a "Done, 14 files changed" title that had to be corrected in each copy.
///
/// One definition per card, then. Both menus build their items from here, so a
/// card added for one appears in the other, and a payload fixed once is fixed
/// everywhere.
enum DemoCards {
    static let source = "Demo"

    // MARK: - Permission cards

    static func permission() -> PermissionRequest {
        PermissionRequest(
            kind: .toolUse, title: "Run shell command", detail: "npm install",
            toolName: "Bash", source: source, cwd: NSHomeDirectory(),
            dangerReasons: [], resolver: { _, _ in })
    }

    /// Exercises the red banner and hold-to-allow without waiting for Claude
    /// Code to genuinely issue an rm -rf. The reasons come from the real
    /// detector, so this demo also proves the detector still fires.
    static func dangerous() -> PermissionRequest {
        let command = "rm -rf /tmp/cache && sudo chmod -R 777 /Library/LaunchAgents"
        return PermissionRequest(
            kind: .toolUse, title: "Run shell command", detail: command,
            toolName: "Bash", source: source, cwd: NSHomeDirectory(),
            dangerReasons: ToolPreviewParser.dangerReasons(for: "Bash",
                                                           input: ["command": command]),
            resolver: { _, _ in })
    }

    /// Exercises the diff preview, red old lines above green new ones.
    static func diff() -> PermissionRequest {
        let preview = ToolPreviewParser.preview(for: "Edit", input: [
            "file_path": "/Users/example/main.swift",
            "old_string": "let x = 42\nprint(\"hello\")\nreturn x",
            "new_string": "let x = 100\nprint(\"hello, world\")\nreturn x * 2",
        ])
        return PermissionRequest(
            kind: .toolUse, title: "Edit file", detail: "/Users/example/main.swift",
            toolName: "Edit", source: source, cwd: "/Users/example",
            preview: preview, resolver: { _, _ in })
    }

    /// The button-less card Auto-Approve shows after silently allowing an edit.
    static func autoApproved() -> PermissionRequest {
        let preview = ToolPreviewParser.preview(for: "Edit", input: [
            "file_path": "/Users/example/config.swift",
            "old_string": "timeout = 30",
            "new_string": "timeout = 60",
        ])
        return PermissionRequest(
            kind: .toolUse, title: "Edit file", detail: "/Users/example/config.swift",
            toolName: "Edit", source: source, cwd: "/Users/example",
            preview: preview, resolver: { _, _ in })
    }

    static func notification() -> PermissionRequest {
        PermissionRequest(
            kind: .notification, title: "Claude is waiting for your input",
            detail: "Open IDE to continue", toolName: "Notification",
            source: source, cwd: "", resolver: { _, _ in })
    }

    // MARK: - Finished tasks

    static func completed() -> CompletedTask {
        CompletedTask(
            title: "Done, 14 files changed, tests green",
            detail: "Refactored auth middleware and re-ran the suite.",
            source: source, cwd: NSHomeDirectory())
    }

    /// A finished task carrying one of the completion audit's verdicts.
    ///
    /// The real thing needs a turn whose closing message disagrees with what
    /// its tools did, which cannot be staged on demand, so without this the
    /// headline case is unreachable by hand.
    static func audited(_ verdict: CompletionAudit.Verdict) -> CompletedTask {
        let task = CompletedTask(
            title: "Fixed the ordering in the phase machine",
            detail: "Claude said it was done.",
            source: source, cwd: NSHomeDirectory())
        task.audit = verdict
        return task
    }

    /// Extraction anchors for the verdict titles below.
    ///
    /// Settings looks those titles up through a variable now that both menus
    /// read one list, and tools/l10n-extract.py only sees literal call sites.
    /// Without these the three rows drop out of the strings table and quietly
    /// stop being translatable, which nothing else would report. Never called.
    static let localizedDemoKeys: [String] = [
        L("Task complete: claim contradicted", comment: "Settings button"),
        L("Task complete: not demonstrated", comment: "Settings button"),
        L("Task complete: verified", comment: "Settings button"),
    ]

    /// The three verdicts, in the order they are worth demonstrating: the one
    /// that accuses, the one that cannot confirm, the one that agrees.
    static let auditVerdicts: [(title: String, symbol: String, verdict: CompletionAudit.Verdict)] = [
        ("Task complete: claim contradicted", "exclamationmark.triangle",
         .contradicted("Claude says it changed the code, but this turn edited no file and ran no command.")),
        ("Task complete: not demonstrated", "questionmark.circle",
         .unverified("Claude says the tests pass, but no test command ran this turn.")),
        ("Task complete: verified", "checkmark.circle",
         .verified("2 files changed, tests passed.")),
    ]
}
