import XCTest
@testable import ClaudeNotch

/// A bloated instruction file gets skimmed and takes the rules that matter with
/// it. Both symptoms are checkable without reading a word of the content, and
/// both bars sit above the recommendation, because telling somebody their
/// careful file is a problem is the expensive way to be wrong.
final class InstructionsBloatTests: XCTestCase {

    private func file(lines: Int, emphasised: Int = 0) -> String {
        var out: [String] = []
        for i in 0..<emphasised { out.append("IMPORTANT: rule \(i)") }
        while out.count < lines { out.append("ordinary line") }
        return out.joined(separator: "\n")
    }

    // MARK: - Length

    func testAShortFileIsFine() {
        XCTAssertFalse(InstructionsBloat.inspect(file(lines: 120)).worthSaying)
    }

    func testALongFileIsWorthSaying() {
        let f = InstructionsBloat.inspect(file(lines: InstructionsBloat.longFile + 50))
        XCTAssertTrue(f.isLong)
        XCTAssertTrue(f.worthSaying)
    }

    /// The bar is deliberately above the usual advice, so a file at the
    /// recommended length is never called a problem.
    func testTheBarSitsAboveTheRecommendation() {
        XCTAssertGreaterThan(InstructionsBloat.longFile, 200)
        XCTAssertFalse(InstructionsBloat.inspect(file(lines: 200)).isLong)
    }

    // MARK: - Emphasis

    func testOneEmphasisedLineIsTheRecommendation() {
        XCTAssertFalse(InstructionsBloat.inspect(file(lines: 50, emphasised: 1)).isShouty)
    }

    func testTooMuchEmphasisIsWorthSaying() {
        let f = InstructionsBloat.inspect(file(lines: 50, emphasised: InstructionsBloat.tooMuchEmphasis))
        XCTAssertTrue(f.isShouty)
        XCTAssertTrue(f.worthSaying)
    }

    /// A line shouting twice is still one shouted line. Counting occurrences
    /// rather than lines would make a single rule look like several.
    func testALineIsCountedOnceHoweverLoud() {
        let f = InstructionsBloat.inspect("IMPORTANT: do it. IMPORTANT: really.\nplain")
        XCTAssertEqual(f.emphasised, 1)
    }

    func testTheMarkersAreCaseSensitiveShouting() {
        // Lowercase prose is not emphasis, or every sentence with "always" in
        // it would count.
        XCTAssertEqual(InstructionsBloat.inspect("we always run tests\nand never skip").emphasised, 0)
    }

    // MARK: - Reading a real file

    func testAMissingFileIsNotAFinding() {
        XCTAssertNil(InstructionsBloat.read(path: "/nonexistent/CLAUDE.md"))
    }

    /// This repo's own instruction file must not trip either bar, which is the
    /// closest thing to a real-world check available here.
    func testThisRepoIsNotAccused() throws {
        let path = FileManager.default.currentDirectoryPath + "/CLAUDE.md"
        guard let f = InstructionsBloat.read(path: path) else {
            throw XCTSkip("run from the repo root to check the real file")
        }
        XCTAssertFalse(f.worthSaying, "lines=\(f.lines) emphasised=\(f.emphasised)")
    }

    // MARK: - What it says

    func testTheCardsDifferByProblem() {
        let long = InstructionsBloat.Finding(lines: 900, emphasised: 0)
        let shouty = InstructionsBloat.Finding(lines: 50, emphasised: 9)
        XCTAssertTrue(InstructionsBloat.cardTitle(long).contains("900"))
        XCTAssertTrue(InstructionsBloat.cardTitle(shouty).contains("9"))
        XCTAssertNotEqual(InstructionsBloat.cardDetail(long), InstructionsBloat.cardDetail(shouty))
    }
}
