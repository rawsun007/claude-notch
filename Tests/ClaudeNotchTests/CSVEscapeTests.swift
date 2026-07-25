import XCTest
@testable import ClaudeNotch

/// History/session CSV exports carry agent-supplied tool commands, file paths,
/// and session notes. csvEscape is the gate that keeps a crafted field from
/// being evaluated as a formula when the file is opened in Excel/Sheets, on top
/// of the RFC 4180 quoting.
final class CSVEscapeTests: XCTestCase {

    func testPlainFieldUnchanged() {
        XCTAssertEqual(AppState.csvEscape("Bash"), "Bash")
        XCTAssertEqual(AppState.csvEscape("/tmp/file.swift"), "/tmp/file.swift")
    }

    func testCommaQuoteNewlineQuoted() {
        XCTAssertEqual(AppState.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(AppState.csvEscape("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(AppState.csvEscape("a\nb"), "\"a\nb\"")
        XCTAssertEqual(AppState.csvEscape("a\rb"), "\"a\rb\"")
    }

    func testFormulaLeadingCharsNeutralized() {
        // Each dangerous leading char gets a single-quote prefix.
        XCTAssertEqual(AppState.csvEscape("=1+1"), "'=1+1")
        XCTAssertEqual(AppState.csvEscape("+cmd"), "'+cmd")
        XCTAssertEqual(AppState.csvEscape("-2+3"), "'-2+3")
        XCTAssertEqual(AppState.csvEscape("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(AppState.csvEscape("\tx"), "'\tx")
    }

    func testFormulaWithSeparatorBothApplied() {
        // A formula field that also needs RFC 4180 quoting gets the quote prefix
        // inside the surrounding double quotes.
        XCTAssertEqual(AppState.csvEscape("=HYPERLINK(\"x\",\"y\")"),
                       "\"'=HYPERLINK(\"\"x\"\",\"\"y\"\")\"")
    }

    func testFormulaCharMidFieldIsSafe() {
        // = not at the start is not a formula trigger.
        XCTAssertEqual(AppState.csvEscape("a=b"), "a=b")
    }

    func testEmptyStays() {
        XCTAssertEqual(AppState.csvEscape(""), "")
    }
}
