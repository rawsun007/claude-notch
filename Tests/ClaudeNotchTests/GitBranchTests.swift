import XCTest
@testable import ClaudeNotch

/// Git.branch reads .git/HEAD by hand (no shelling out) for the notch's branch
/// label and the standup. It has to survive the shapes a real checkout takes:
/// a nested cwd, a slash-bearing branch name, a detached HEAD, and a worktree
/// whose ".git" is a file pointing elsewhere. Each is easy to get subtly wrong.
final class GitBranchTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitbranch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Lay down `root/.git/HEAD` with the given contents and return the repo dir.
    @discardableResult
    private func makeRepo(head: String) throws -> URL {
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try head.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return root
    }

    func testBranchAtRoot() throws {
        try makeRepo(head: "ref: refs/heads/main\n")
        XCTAssertEqual(Git.branch(forCwd: root.path), "main")
    }

    func testWalksUpFromNestedDir() throws {
        try makeRepo(head: "ref: refs/heads/main\n")
        let nested = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(Git.branch(forCwd: nested.path), "main")
    }

    func testSlashBearingBranchName() throws {
        try makeRepo(head: "ref: refs/heads/feature/new-thing\n")
        XCTAssertEqual(Git.branch(forCwd: root.path), "feature/new-thing")
    }

    func testDetachedHeadReturnsShortHash() throws {
        try makeRepo(head: "0123456789abcdef0123456789abcdef01234567\n")
        XCTAssertEqual(Git.branch(forCwd: root.path), "0123456")
    }

    func testNotARepoReturnsEmpty() {
        XCTAssertEqual(Git.branch(forCwd: root.path), "")
    }

    func testEmptyCwdReturnsEmpty() {
        XCTAssertEqual(Git.branch(forCwd: ""), "")
    }

    func testWorktreeGitFilePointsToRealGitdir() throws {
        // Real gitdir lives elsewhere; the repo's ".git" is a file pointing to it.
        let realGitDir = root.appendingPathComponent("realgit")
        try FileManager.default.createDirectory(at: realGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/wt-branch\n".write(
            to: realGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let workDir = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try "gitdir: \(realGitDir.path)\n".write(
            to: workDir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(Git.branch(forCwd: workDir.path), "wt-branch")
    }
}
