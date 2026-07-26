import XCTest
@testable import ClaudeNotch

/// AskUserQuestion payloads arrive in two shapes (our own {questions:[...]} and
/// Claude Code's full PreToolUse JSON with tool_input.questions). parseQuestions
/// is the one definition both question handlers use; it must accept both shapes
/// and drop malformed entries.
final class ParseQuestionsTests: XCTestCase {

    func testOwnShape() {
        let payload: [String: Any] = ["questions": [
            ["question": "Pick one", "header": "H", "multiSelect": true,
             "options": [["label": "A", "description": "first"], ["label": "B"]]],
        ]]
        let qs = EventServer.parseQuestions(from: payload)
        XCTAssertEqual(qs.count, 1)
        XCTAssertEqual(qs[0].text, "Pick one")
        XCTAssertEqual(qs[0].header, "H")
        XCTAssertTrue(qs[0].multiSelect)
        XCTAssertEqual(qs[0].options.map(\.label), ["A", "B"])
        XCTAssertEqual(qs[0].options[0].description, "first")
        XCTAssertEqual(qs[0].options[1].description, "")   // missing description -> ""
    }

    func testToolInputShape() {
        let payload: [String: Any] = ["tool_input": ["questions": [
            ["question": "Q", "options": [["label": "Yes"]]],
        ]]]
        let qs = EventServer.parseQuestions(from: payload)
        XCTAssertEqual(qs.count, 1)
        XCTAssertFalse(qs[0].multiSelect)   // default
    }

    func testDropsMalformed() {
        let payload: [String: Any] = ["questions": [
            ["header": "no question text", "options": [["label": "A"]]],  // missing question
            ["question": "no options"],                                   // no options
            ["question": "ok", "options": [["description": "no label"]]], // option missing label -> empty -> dropped
            ["question": "good", "options": [["label": "A"]]],
        ]]
        let qs = EventServer.parseQuestions(from: payload)
        XCTAssertEqual(qs.map(\.text), ["good"])
    }

    func testEmptyWhenAbsent() {
        XCTAssertTrue(EventServer.parseQuestions(from: [:]).isEmpty)
    }
}
