import XCTest
@testable import ClaudeNotch

/// APIKeyValidator never makes a network call in tests (no network in CI), so
/// these cover the pure pieces: shape checking, masking, and turning an HTTP
/// status into a verdict.
final class APIKeyValidatorTests: XCTestCase {

    func testLooksValidAcceptsARealShape() {
        XCTAssertTrue(APIKeyValidator.looksValid("sk-ant-api03-" + String(repeating: "a", count: 20)))
    }

    func testLooksValidRejectsWrongPrefix() {
        XCTAssertFalse(APIKeyValidator.looksValid("sk-proj-" + String(repeating: "a", count: 20)))
    }

    func testLooksValidRejectsTooShort() {
        XCTAssertFalse(APIKeyValidator.looksValid("sk-ant-short"))
    }

    func testLooksValidRejectsEmpty() {
        XCTAssertFalse(APIKeyValidator.looksValid(""))
    }

    /// The point of masking is that the real key never appears in the result.
    func testMaskedNeverContainsTheKey() {
        let key = "sk-ant-api03-XYZ1234567890ABCDEFGHIJ"
        let masked = APIKeyValidator.masked(key)
        XCTAssertFalse(masked.contains(key))
        XCTAssertTrue(masked.hasSuffix("GHIJ"))
        XCTAssertTrue(masked.hasPrefix("sk-ant-"))
    }

    func testMaskedHandlesAShortString() {
        // Never crash or echo back something short enough to just be the key.
        XCTAssertEqual(APIKeyValidator.masked("abc"), String(repeating: "•", count: 8))
    }

    func testInterpretSuccess() {
        XCTAssertEqual(APIKeyValidator.interpret(statusCode: 200), .valid)
        XCTAssertEqual(APIKeyValidator.interpret(statusCode: 204), .valid)
    }

    /// Rate-limited still means the key was accepted: Anthropic checks auth
    /// before rate limits.
    func testInterpretRateLimitedIsStillValid() {
        XCTAssertEqual(APIKeyValidator.interpret(statusCode: 429), .valid)
    }

    func testInterpretUnauthorized() {
        guard case .invalid = APIKeyValidator.interpret(statusCode: 401) else {
            return XCTFail("401 should be .invalid")
        }
    }

    func testInterpretForbidden() {
        guard case .invalid = APIKeyValidator.interpret(statusCode: 403) else {
            return XCTFail("403 should be .invalid")
        }
    }

    func testInterpretServerErrorIsNetworkError() {
        guard case .networkError = APIKeyValidator.interpret(statusCode: 500) else {
            return XCTFail("500 should be .networkError")
        }
    }
}
