import XCTest
@testable import ClaudeNotch

/// FileSlice feeds the transcript and rollout parsers, which are line-oriented:
/// a slice that leaks a partial line at the cut would hand a JSON parser half a
/// record. These pin the "drop the partial line at the boundary" contract and
/// the nil-means-couldn't-open signal.
final class FileSliceTests: XCTestCase {

    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileslice-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: tail

    func testTailWholeFileWhenUnderCap() throws {
        let url = try write("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(at: url) }
        // Cap larger than file: start stays 0, so no leading line is dropped.
        XCTAssertEqual(FileSlice.tail(url, bytes: 4096), "a\nb\nc\n")
    }

    func testTailDropsLeadingPartialLine() throws {
        // 10 lines "line0".."line9", each 6 bytes ("lineN\n") = 60 bytes total.
        let body = (0..<10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let url = try write(body)
        defer { try? FileManager.default.removeItem(at: url) }
        // Ask for the last 20 bytes: the cut lands mid-line, and that partial
        // head must be dropped so the first surviving line is whole.
        let s = FileSlice.tail(url, bytes: 20)
        XCTAssertNotNil(s)
        let first = s!.split(separator: "\n").first.map(String.init)
        XCTAssertEqual(first, "line7") // whole line, not a "ne7" fragment
        XCTAssertTrue(s!.hasSuffix("line9\n"))
    }

    func testTailNilOnMissingFile() {
        let url = URL(fileURLWithPath: "/nope/\(UUID().uuidString)")
        XCTAssertNil(FileSlice.tail(url, bytes: 100))
    }

    // MARK: head

    func testHeadWholeFileWhenUnderCap() throws {
        let url = try write("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(at: url) }
        // Read fewer bytes than the cap: no trailing line is dropped.
        XCTAssertEqual(FileSlice.head(url, bytes: 4096), "a\nb\nc\n")
    }

    func testHeadDropsTrailingPartialLine() throws {
        let body = (0..<10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let url = try write(body)
        defer { try? FileManager.default.removeItem(at: url) }
        // Read hits the cap, so there is more file after it: the last line is
        // partial and must be dropped.
        let s = FileSlice.head(url, bytes: 20)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.hasPrefix("line0\n"))
        let last = s!.split(separator: "\n").last.map(String.init)
        XCTAssertEqual(last, "line2") // whole line, not "lin"
    }

    func testHeadNilOnMissingFile() {
        let url = URL(fileURLWithPath: "/nope/\(UUID().uuidString)")
        XCTAssertNil(FileSlice.head(url, bytes: 100))
    }
}
