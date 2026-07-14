import XCTest
@testable import ClaudeNotch

/// What earns a row in the session history. The bar is "Claude did something",
/// not "a hook arrived" — see AppState.isWorthArchiving.
final class SessionArchiveTests: XCTestCase {

    private func session(tokens: Int = 0, cost: Double = 0, tools: Int = 0,
                         files: [String] = [], cwd: String = "/Users/me/project") -> LiveSession {
        var s = LiveSession(
            id: UUID().uuidString,
            cwd: cwd,
            project: (cwd as NSString).lastPathComponent,
            status: "ready",
            activity: "",
            lastResponse: "",
            fullResponse: "",
            originatorBundleID: nil,
            lastHookAt: Date(),
            createdAt: Date()
        )
        s.contextTokens = tokens
        s.sessionCostUSD = cost
        s.toolCallCount = tools
        s.touchedFiles = files
        return s
    }

    func testARealSessionIsArchived() {
        XCTAssertTrue(AppState.isWorthArchiving(session(tokens: 40_000, cost: 1.2, tools: 9)))
        // Money alone, or a file alone, is enough — the transcript may not have
        // been readable, but the work plainly happened.
        XCTAssertTrue(AppState.isWorthArchiving(session(cost: 0.4)))
        XCTAssertTrue(AppState.isWorthArchiving(session(files: ["/Users/me/project/main.swift"])))
    }

    func testAStrayHookIsNotASession() {
        // A single hook POST carries a cwd, so it always had a project name, and
        // it could carry a tool name too. Under the old rule that was enough to
        // become a history row — which is how one-second sessions named after
        // scratch directories ended up in the list.
        XCTAssertFalse(AppState.isWorthArchiving(session(tools: 1, cwd: "/tmp/race")))
        XCTAssertFalse(AppState.isWorthArchiving(session()))
    }

    func testOldJunkRowsAreSweptOnLoad() {
        let junk = SessionRecord(sessionKey: "race-test-1", project: "race", cwd: "/tmp/race",
                                 startedAt: Date(), endedAt: Date(),
                                 contextTokens: 0, costUSD: 0, toolCallCount: 1)
        let real = SessionRecord(sessionKey: "abc", project: "project", cwd: "/Users/me/project",
                                 startedAt: Date(), endedAt: Date(),
                                 contextTokens: 90_009, costUSD: 4.21, toolCallCount: 46)
        XCTAssertFalse(AppState.isWorthKeeping(junk))
        XCTAssertTrue(AppState.isWorthKeeping(real))
    }
}

/// Scratch directories are not projects. A one-off run in a temp folder is real
/// work (it burns tokens and costs money, so the "did Claude do something" rule
/// keeps it) but it does not belong in a list of projects, next to a repo you have
/// spent a fortnight in, when it will not exist tomorrow.
final class ScratchDirectoryTests: XCTestCase {

    func testTempDirectoriesAreNotProjects() {
        XCTAssertFalse(AppState.isRealProject("/tmp/scratchpad"))
        XCTAssertFalse(AppState.isRealProject("/private/tmp/claude-501/abc/scratchpad"))
        XCTAssertFalse(AppState.isRealProject("/var/folders/c7/xyz/T/whatever"))
        XCTAssertFalse(AppState.isRealProject("/tmp"))
        XCTAssertFalse(AppState.isRealProject(""))
    }

    func testRealProjectsAre() {
        XCTAssertTrue(AppState.isRealProject("/Users/me/claude mac app"))
        XCTAssertTrue(AppState.isRealProject("/Users/me/dev/repo"))
        // Not fooled by a project whose name merely starts the same way.
        XCTAssertTrue(AppState.isRealProject("/Users/me/tmpfiles"))
        XCTAssertTrue(AppState.isRealProject("/Users/me/var/folders-app"))
    }

    func testAScratchRunIsNotArchived() {
        let scratch = SessionRecord(sessionKey: "bg", project: "scratchpad",
                                    cwd: "/private/tmp/claude-501/abc/scratchpad",
                                    startedAt: Date(), endedAt: Date(),
                                    contextTokens: 24_000, costUSD: 0.08, toolCallCount: 1)
        XCTAssertFalse(AppState.isWorthKeeping(scratch),
                       "real work, but not a project: it will not exist tomorrow")

        let real = SessionRecord(sessionKey: "abc", project: "claude mac app",
                                 cwd: "/Users/me/claude mac app",
                                 startedAt: Date(), endedAt: Date(),
                                 contextTokens: 600_000, costUSD: 268, toolCallCount: 10)
        XCTAssertTrue(AppState.isWorthKeeping(real))
    }
}
