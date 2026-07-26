import XCTest
@testable import ClaudeNotch

/// Shell.quote is the single shell-injection boundary: every terminal launcher
/// (cd into a dir, run `claude "message"`, resume a session id) embeds
/// payload-derived strings through it. A hole here means a crafted directory
/// name or message could break out of its quotes and run arbitrary commands.
/// These tests pin the escaping AND prove, by evaluating through /bin/sh, that
/// the quoted form always parses back to the exact original with no expansion.
final class ShellQuoteTests: XCTestCase {

    func testWrapsAndEscapes() {
        XCTAssertEqual(Shell.quote("abc"), "'abc'")
        XCTAssertEqual(Shell.quote(""), "''")
        // A single quote closes, escapes, reopens: '\''
        XCTAssertEqual(Shell.quote("a'b"), "'a'\\''b'")
    }

    /// Run `sh -c "printf %s <quoted>"` and return exactly what the shell passed
    /// as the argument. If quoting is correct this equals the input untouched;
    /// if it is broken, the shell expands/splits/executes and this diverges.
    private func roundTrip(_ s: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s \(Shell.quote(s))"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    func testRoundTripNeutralizesInjection() {
        let hostile = [
            "plain",
            "with spaces",
            "a'b",                       // embedded single quote
            "$(rm -rf /)",               // command substitution
            "`whoami`",                  // backtick substitution
            "$HOME/$USER",               // variable expansion
            "'; rm -rf / ; '",           // quote-break attempt
            "a\"b",                      // double quote
            "a\\b",                      // backslash
            "line1\nline2",             // newline
            "tab\tend",                 // tab
            "*.swift",                   // glob
            "a & b | c ; d",             // shell metacharacters
            "~/Library",                 // tilde
            "emoji 🐱 and é",            // multibyte utf-8
        ]
        for s in hostile {
            XCTAssertEqual(roundTrip(s), s, "quoting failed to neutralize: \(s.debugDescription)")
        }
    }
}
