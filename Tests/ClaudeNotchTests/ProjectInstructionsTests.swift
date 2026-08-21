import XCTest
@testable import ClaudeNotch

/// A CLAUDE.md is the only context an agent carries into every task without
/// being asked. The two ways it goes wrong are both quiet: there isn't one, or
/// there is one that stopped being true months ago.
final class ProjectInstructionsTests: XCTestCase {

    private var dir = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-proj-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func write(_ name: String, ageDays: Double = 0) throws {
        let path = (dir as NSString).appendingPathComponent(name)
        try "# instructions".write(toFile: path, atomically: true, encoding: .utf8)
        let when = Date().addingTimeInterval(-ageDays * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: path)
    }

    func testAProjectWithNoInstructionsIsMissing() {
        XCTAssertEqual(ProjectInstructions.status(cwd: dir), .missing)
    }

    func testARecentFileIsCurrent() throws {
        try write("CLAUDE.md", ageDays: 3)
        guard case .current = ProjectInstructions.status(cwd: dir) else {
            return XCTFail("a file touched three days ago is current")
        }
    }

    func testAnOldFileIsStale() throws {
        try write("CLAUDE.md", ageDays: 90)
        guard case .stale(_, let age) = ProjectInstructions.status(cwd: dir) else {
            return XCTFail("a file untouched for ninety days is stale")
        }
        XCTAssertGreaterThan(age, ProjectInstructions.staleAfter)
    }

    /// Generous on purpose: a stable project can have a correct file nobody has
    /// touched in a month, and nagging about a file that is right is how this
    /// gets switched off.
    func testTheStalenessBarIsGenerous() throws {
        try write("CLAUDE.md", ageDays: 30)
        guard case .current = ProjectInstructions.status(cwd: dir) else {
            return XCTFail("thirty days is not stale")
        }
        XCTAssertGreaterThanOrEqual(ProjectInstructions.staleAfter, 30 * 24 * 3600)
    }

    func testTheOtherNamesCount() throws {
        try write("AGENTS.md", ageDays: 1)
        guard case .current = ProjectInstructions.status(cwd: dir) else {
            return XCTFail("AGENTS.md counts as instructions")
        }
    }

    /// A clock problem is not an ancient file, and treating it as one would be
    /// wrong in the loud direction.
    func testAFutureTimestampIsNotStale() throws {
        try write("CLAUDE.md", ageDays: -5)
        guard case .current = ProjectInstructions.status(cwd: dir) else {
            return XCTFail("a future mtime is not staleness")
        }
    }

    func testANonProjectIsUnknown() {
        XCTAssertEqual(ProjectInstructions.status(cwd: ""), .unknown)
        XCTAssertEqual(ProjectInstructions.status(cwd: "/"), .unknown)
        XCTAssertEqual(ProjectInstructions.status(cwd: "/nonexistent/place"), .unknown)
    }

    // MARK: - When it is worth saying

    /// Not for a one-line question in a scratch directory.
    func testAQuietSessionIsNotAdvised() {
        XCTAssertFalse(ProjectInstructions.worthAdvising(.missing, toolCalls: 2))
        XCTAssertTrue(ProjectInstructions.worthAdvising(.missing,
                                                        toolCalls: ProjectInstructions.toolCallsBeforeAdvising))
    }

    func testAGoodProjectIsNeverAdvised() {
        XCTAssertFalse(ProjectInstructions.worthAdvising(.current(path: "/x/CLAUDE.md"), toolCalls: 500))
        XCTAssertFalse(ProjectInstructions.worthAdvising(.unknown, toolCalls: 500))
    }

    func testBothProblemsSaySomethingDifferent() {
        let missing = ProjectInstructions.title(.missing)
        let stale = ProjectInstructions.title(.stale(path: "/x/CLAUDE.md", age: 90 * 24 * 3600))
        XCTAssertNotEqual(missing, stale)
        XCTAssertFalse(ProjectInstructions.detail(.missing).isEmpty)
        // The stale one names the file and how old it is, since "it is old" on
        // its own is not actionable.
        let detail = ProjectInstructions.detail(.stale(path: "/x/CLAUDE.md", age: 90 * 24 * 3600))
        XCTAssertTrue(detail.contains("CLAUDE.md"), detail)
        XCTAssertTrue(detail.contains("days"), detail)
        XCTAssertEqual(ProjectInstructions.title(.current(path: "/x")), "")
    }

    // MARK: - On a session

    @MainActor
    private func state(cwd: String, toolCalls: Int) -> AppState {
        let s = AppState()
        s.currentCwd = cwd
        s.upsertSession(id: "s1", cwd: cwd, create: true) { $0.toolCallCount = toolCalls }
        return s
    }

    @MainActor
    func testAProjectIsAdvisedOnceNoMatterHowManySessions() {
        let s = state(cwd: dir, toolCalls: 50)
        s.adviseProjectInstructionsIfNeeded(sessionId: "s1", cwd: dir)
        s.adviseProjectInstructionsIfNeeded(sessionId: "s1", cwd: dir)
        // A second session in the same project must not repeat it.
        s.upsertSession(id: "s2", cwd: dir, create: true) { $0.toolCallCount = 50 }
        s.adviseProjectInstructionsIfNeeded(sessionId: "s2", cwd: dir)

        XCTAssertEqual(s.permissionQueue.filter { $0.toolName == "Instructions" }.count, 1)
    }

    @MainActor
    func testAProjectWithGoodInstructionsHearsNothing() throws {
        try write("CLAUDE.md", ageDays: 1)
        let s = state(cwd: dir, toolCalls: 50)
        s.adviseProjectInstructionsIfNeeded(sessionId: "s1", cwd: dir)
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }

    /// The same switch that silences the compaction nudge silences this: it is
    /// the same question, "should this app offer advice".
    @MainActor
    func testTheNudgeSettingSilencesIt() {
        let s = state(cwd: dir, toolCalls: 50)
        s.setCompactAdviceEnabled(false)
        s.adviseProjectInstructionsIfNeeded(sessionId: "s1", cwd: dir)
        XCTAssertTrue(s.permissionQueue.isEmpty)
    }
}
