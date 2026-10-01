import XCTest
@testable import ClaudeNotch

/// Claude Code 2.1.260 says why a prompt cache missed. The forwarder sends the
/// cause names comma separated; the tooltip turns them into a sentence.
final class PromptCacheCauseTests: XCTestCase {
    func testNothingDiagnosedSaysNothing() {
        XCTAssertEqual(PromptCacheState.causeText(""), "")
        XCTAssertEqual(PromptCacheState.causeText(" , "), "")
    }

    func testKnownCauses() {
        XCTAssertTrue(PromptCacheState.causeText("tools_changed").contains("tool list changed"))
        XCTAssertTrue(PromptCacheState.causeText("system_prompt_changed").contains("system prompt changed"))
        XCTAssertTrue(PromptCacheState.causeText("ttl_expired_5m").contains("5m lifetime"))
        XCTAssertTrue(PromptCacheState.causeText("likely_server_side").contains("server"))
    }

    func testSeveralAndUnknown() {
        let text = PromptCacheState.causeText("tools_changed,model_swapped")
        XCTAssertTrue(text.hasPrefix("Last miss:"))
        XCTAssertTrue(text.contains("; model swapped"))
    }
}
