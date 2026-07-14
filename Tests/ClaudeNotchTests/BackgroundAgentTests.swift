import XCTest
@testable import ClaudeNotch

/// The daemon roster (`~/.claude/daemon/roster.json`). Recorded from a real
/// `claude --bg` run, because the shape of this file is the whole feature: it is
/// the only place the short id (`claude attach` takes it) and the task intent
/// exist.
final class BackgroundAgentTests: XCTestCase {

    private let roster = """
    {
      "proto": 1,
      "supervisorPid": 4242,
      "updatedAt": 1784018413640,
      "workers": {
        "703d48dc": {
          "pid": 53273,
          "sessionId": "703d48dc-f2f2-4592-8885-6734e6555839",
          "cliVersion": "2.1.209",
          "startedAt": 1784018336500,
          "cwd": "/Users/me/project",
          "dispatch": {
            "short": "703d48dc",
            "source": "shell",
            "seed": { "intent": "Reply with exactly: hello from a background agent." }
          }
        },
        "9f10aa22": {
          "pid": 53999,
          "sessionId": "9f10aa22-0000-4592-8885-6734e6555839",
          "startedAt": 1784018400000,
          "cwd": "/Users/me/other",
          "dispatch": { "short": "9f10aa22", "seed": { "intent": "Fix the failing test" } }
        }
      }
    }
    """.data(using: .utf8)!

    private func parse(alive: @escaping (Int32) -> Bool = { _ in true }) -> [BackgroundAgent] {
        BackgroundAgentReader.parse(roster, isAlive: alive)
    }

    func testAnAgentIsNamedByWhatItWasAskedToDo() {
        // A background agent has no terminal, no window, and its folder name says
        // nothing about the job. The intent is its only human-readable label.
        let agents = parse()
        XCTAssertEqual(agents.count, 2)
        let first = agents.first { $0.id == "703d48dc" }
        XCTAssertEqual(first?.intent, "Reply with exactly: hello from a background agent.")
        XCTAssertEqual(first?.sessionId, "703d48dc-f2f2-4592-8885-6734e6555839")
        XCTAssertEqual(first?.cwd, "/Users/me/project")
        XCTAssertEqual(first?.project, "project")
    }

    func testNewestAgentComesFirst() {
        XCTAssertEqual(parse().map(\.id), ["9f10aa22", "703d48dc"])
    }

    func testStartedAtIsReadAsMilliseconds() {
        // The daemon writes epoch MILLIseconds. Reading them as seconds puts the
        // agent's start date in the year 58,500.
        let agent = parse().first { $0.id == "703d48dc" }
        let started = try! XCTUnwrap(agent?.startedAt)
        XCTAssertEqual(started.timeIntervalSince1970, 1784018336.5, accuracy: 0.01)
    }

    func testADeadWorkerIsNotAnAgent() {
        // The daemon can leave a stale entry behind (a crash, a machine that
        // slept). Listing a dead agent as running is worse than not listing it:
        // the entire point of the row is that something is still working.
        let onlyOneAlive = parse { $0 == 53273 }
        XCTAssertEqual(onlyOneAlive.map(\.id), ["703d48dc"])
        XCTAssertTrue(parse { _ in false }.isEmpty)
    }

    func testAttachCommandUsesTheShortId() {
        let agent = parse().first { $0.id == "703d48dc" }!
        XCTAssertEqual(BackgroundAgentReader.attachCommand(agent), "claude attach 703d48dc")
    }

    func testGarbageIsNotAnAgent() {
        XCTAssertTrue(BackgroundAgentReader.parse(Data()).isEmpty)
        XCTAssertTrue(BackgroundAgentReader.parse("{}".data(using: .utf8)!).isEmpty)
        XCTAssertTrue(BackgroundAgentReader.parse(#"{"workers": {}}"#.data(using: .utf8)!).isEmpty)
    }
}
