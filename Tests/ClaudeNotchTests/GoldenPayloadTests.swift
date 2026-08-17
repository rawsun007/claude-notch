import XCTest
@testable import ClaudeNotch

/// Golden tests over the hook payloads.
///
/// Every parser in this app reads JSON written by someone else: Claude Code,
/// Codex, an MCP server. The payloads are real ones, captured from those
/// programs, and each is pinned to a one-line summary of what this app makes of
/// it. A parser change that alters any of these flips a string here, which is
/// the point: the failure names the payload and shows both readings, so the
/// question at review time is "is the new reading right", not "what changed".
///
/// Adding a case: paste the payload, run the suite, and copy the actual line
/// into `expected` after checking it says what it should.
final class GoldenPayloadTests: XCTestCase {

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    /// One stable line describing everything this app extracts from a payload.
    private func summary(_ payload: [String: Any]) -> String {
        let event = (payload["hook_event_name"] as? String) ?? "?"
        switch event {
        case "PostCompact":
            let trigger = (payload["trigger"] as? String) ?? ""
            let summary = (payload["compact_summary"] as? String) ?? ""
            return "compacted trigger=\(trigger) summary=\(summary.prefix(20))"

        case "Elicitation":
            guard let form = ElicitationParser.form(from: payload) else { return "elicitation declined" }
            let fields = form.fields.map { "\($0.name)[\($0.options.joined(separator: "|"))]" }
            return "elicitation server=\(form.serverName) fields=\(fields.joined(separator: ","))"

        case "PostToolUseFailure":
            guard let e = ToolFailure.parse(payload) else { return "failure ignored" }
            return "failure tool=\(e.toolName) record=\(e.isWorthRecording) reason=\(e.reason)"

        case "PostToolUse":
            let cap = AgentBudgets.capReached(in: payload["tool_response"])
            let tool = (payload["tool_name"] as? String) ?? ""
            return "posttool tool=\(tool) cap=\(cap.map { String(describing: $0) } ?? "none")"

        case "SessionStart":
            let source = (payload["source"] as? String) ?? ""
            let version = (payload["version"] as? String) ?? ""
            let fork = source == "fork" && CLIVersion.supports(.forkSource, version: version)
            return "sessionstart source=\(source) countsAsFork=\(fork)"

        case "AskUserQuestion":
            let qs = EventServer.parseQuestions(from: payload)
            return "questions=" + qs.map { "\($0.header):\($0.options.count)" }.joined(separator: ",")

        default:
            return "unhandled event=\(event)"
        }
    }

    /// Real payloads, and what this app reads out of them.
    private let cases: [(name: String, payload: String, expected: String)] = [

        ("compaction, automatic",
         #"{"hook_event_name":"PostCompact","session_id":"a1","cwd":"/tmp/p","trigger":"auto","compact_summary":"Kept the plan and the open questions."}"#,
         "compacted trigger=auto summary=Kept the plan and th"),

        ("compaction, by hand",
         #"{"hook_event_name":"PostCompact","session_id":"a1","cwd":"/tmp/p","trigger":"manual","compact_summary":""}"#,
         "compacted trigger=manual summary="),

        ("elicitation the card can answer",
         #"{"hook_event_name":"Elicitation","mcp_server_name":"deploy","message":"Where?","mode":"form","elicitation_id":"e1","requested_schema":{"type":"object","properties":{"env":{"type":"string","enum":["dev","prod"]},"force":{"type":"boolean"}},"required":["env"]}}"#,
         "elicitation server=deploy fields=env[dev|prod],force[Yes|No]"),

        ("elicitation asking for free text",
         #"{"hook_event_name":"Elicitation","mcp_server_name":"deploy","message":"Name?","mode":"form","elicitation_id":"e2","requested_schema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}"#,
         "elicitation declined"),

        ("elicitation that wants a browser",
         #"{"hook_event_name":"Elicitation","mcp_server_name":"auth","message":"Sign in","mode":"url","url":"https://example.com/oauth","elicitation_id":"e3","requested_schema":{"type":"object","properties":{"ok":{"type":"boolean"}}}}"#,
         "elicitation declined"),

        ("a build that failed",
         #"{"hook_event_name":"PostToolUseFailure","session_id":"a1","cwd":"/tmp/p","tool_name":"Bash","tool_use_id":"tu1","error":"npm ERR! code ELIFECYCLE\nnpm ERR! errno 1","is_interrupt":false,"duration_ms":8321}"#,
         "failure tool=Bash record=true reason=npm ERR! code ELIFECYCLE"),

        ("the user pressed escape",
         #"{"hook_event_name":"PostToolUseFailure","session_id":"a1","cwd":"/tmp/p","tool_name":"Bash","tool_use_id":"tu2","error":"aborted","is_interrupt":true,"duration_ms":40}"#,
         "failure tool=Bash record=false reason=aborted"),

        ("subagent cap reached",
         #"{"hook_event_name":"PostToolUse","session_id":"a1","cwd":"/tmp/p","tool_name":"Task","tool_response":"Concurrent subagent limit reached. You can run 20 subagents at once. Do not retry."}"#,
         "posttool tool=Task cap=subagents"),

        ("web search budget spent",
         #"{"hook_event_name":"PostToolUse","session_id":"a1","cwd":"/tmp/p","tool_name":"WebSearch","tool_response":{"content":[{"type":"text","text":"Web search was not performed: this session has used its web search budget (200 of 200 WebSearch calls)."}]}}"#,
         "posttool tool=WebSearch cap=webSearches"),

        ("an ordinary tool result",
         #"{"hook_event_name":"PostToolUse","session_id":"a1","cwd":"/tmp/p","tool_name":"Read","tool_response":"import Foundation"}"#,
         "posttool tool=Read cap=none"),

        ("a session that began as a fork",
         #"{"hook_event_name":"SessionStart","session_id":"a1","cwd":"/tmp/p","source":"fork","version":"2.1.233"}"#,
         "sessionstart source=fork countsAsFork=true"),

        ("a fork reported by a build too old to know",
         #"{"hook_event_name":"SessionStart","session_id":"a1","cwd":"/tmp/p","source":"fork","version":"2.1.100"}"#,
         "sessionstart source=fork countsAsFork=false"),

        ("a plain resume",
         #"{"hook_event_name":"SessionStart","session_id":"a1","cwd":"/tmp/p","source":"resume","version":"2.1.233"}"#,
         "sessionstart source=resume countsAsFork=false"),

        ("a question with two multiple-choice parts",
         #"{"hook_event_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Approach","question":"Which way?","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]},{"header":"Scope","question":"How far?","multiSelect":true,"options":[{"label":"X"},{"label":"Y"},{"label":"Z"}]}]}}"#,
         "questions=Approach:2,Scope:3"),
    ]

    func testEveryPayloadStillReadsTheSameWay() {
        for c in cases {
            let actual = summary(json(c.payload))
            XCTAssertEqual(actual, c.expected, """
                golden payload "\(c.name)" changed
                  was: \(c.expected)
                  now: \(actual)
                """)
        }
    }

    /// The fixtures themselves have to be valid, or a typo in one would sit
    /// there passing as an empty dictionary.
    func testEveryFixtureIsRealJSON() {
        for c in cases {
            XCTAssertFalse(json(c.payload).isEmpty, "\(c.name) is not parseable JSON")
        }
    }

    /// A payload the app has no handler for is named as such rather than
    /// silently summarised as nothing.
    func testAnUnknownEventIsReportedAsUnknown() {
        XCTAssertEqual(summary(json(#"{"hook_event_name":"SomethingNew"}"#)),
                       "unhandled event=SomethingNew")
    }
}
