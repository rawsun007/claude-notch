import XCTest
@testable import ClaudeNotch

/// An MCP server's question is untrusted input that ends up as a card with
/// buttons, and whatever the user presses goes back to that server. Both ends
/// are decided here.
final class ElicitationTests: XCTestCase {

    private func payload(mode: String = "form",
                         properties: [String: Any],
                         required: [String] = []) -> [String: Any] {
        [
            "hook_event_name": "Elicitation",
            "mcp_server_name": "deploy-tools",
            "message": "Where should this go?",
            "mode": mode,
            "elicitation_id": "e1",
            "requested_schema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ],
        ]
    }

    // MARK: - What the card can ask

    func testAStringEnumBecomesAMenu() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": ["dev", "prod"], "title": "Environment"],
        ])))
        XCTAssertEqual(form.serverName, "deploy-tools")
        XCTAssertEqual(form.fields.count, 1)
        XCTAssertEqual(form.fields[0].options, ["dev", "prod"])
        XCTAssertFalse(form.fields[0].isBoolean)
        XCTAssertEqual(form.questions.first?.header, "Environment")
    }

    func testABooleanBecomesYesNo() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "overwrite": ["type": "boolean", "description": "Overwrite the file?"],
        ])))
        XCTAssertTrue(form.fields[0].isBoolean)
        XCTAssertEqual(form.fields[0].options, ["Yes", "No"])
        // No title in the schema, so the property name stands in.
        XCTAssertEqual(form.fields[0].title, "overwrite")
    }

    /// The card offers buttons, not a text field. Anything the buttons cannot
    /// express is left to Claude Code's own dialog rather than half-answered.
    func testFreeTextAndNumbersAreDeclined() {
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "name": ["type": "string", "title": "Your name"],
        ])))
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "count": ["type": "integer"],
        ])))
    }

    /// One unanswerable field makes the whole form unanswerable: answering
    /// half a schema fails the server's required check anyway.
    func testAMixedSchemaIsDeclinedWhole() {
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": ["dev", "prod"]],
            "note": ["type": "string"],
        ])))
    }

    /// A URL elicitation is a browser flow. There is nothing to press, and the
    /// notch does not open URLs that arrived on a payload.
    func testUrlModeIsDeclined() {
        XCTAssertNil(ElicitationParser.form(from: payload(mode: "url", properties: [
            "ok": ["type": "boolean"],
        ])))
    }

    func testEmptyAndMalformedSchemasAreDeclined() {
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [:])))
        XCTAssertNil(ElicitationParser.form(from: ["hook_event_name": "Elicitation"]))
        XCTAssertNil(ElicitationParser.form(from: payload(properties: ["a": "not-an-object"])))
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": [1, 2]],
        ])))
    }

    /// Required fields come first, then alphabetical, so the same schema always
    /// draws the same card however the JSON was ordered.
    func testFieldOrderIsStable() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "zebra": ["type": "boolean"],
            "alpha": ["type": "boolean"],
            "must": ["type": "boolean"],
        ], required: ["must"])))
        XCTAssertEqual(form.fields.map(\.name), ["must", "alpha", "zebra"])
    }

    // MARK: - What goes back to the server

    func testAnswersBecomeTypedContent() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": ["dev", "prod"]],
            "overwrite": ["type": "boolean"],
        ])))
        let content = try XCTUnwrap(form.content(from: form.fields.map { f in
            f.isBoolean ? ["Yes"] : ["prod"]
        }))
        XCTAssertEqual(content["env"] as? String, "prod")
        XCTAssertEqual(content["overwrite"] as? Bool, true)
    }

    func testNoBecomesFalse() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "overwrite": ["type": "boolean"],
        ])))
        XCTAssertEqual(try XCTUnwrap(form.content(from: [["No"]]))["overwrite"] as? Bool, false)
    }

    /// A half-answered card is not an answer.
    func testUnansweredFieldsProduceNothing() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": ["dev", "prod"]],
            "overwrite": ["type": "boolean"],
        ])))
        XCTAssertNil(form.content(from: [["prod"]]))
        XCTAssertNil(form.content(from: [["prod"], [""]]))
        XCTAssertNil(form.content(from: []))
    }

    /// The answer that goes back has to be one of the choices the server sent.
    func testAnAnswerOutsideTheEnumIsRefused() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": ["dev", "prod"]],
        ])))
        XCTAssertNil(form.content(from: [["staging"]]))
    }

    /// The options are the schema, so a typed-in answer must not be offered.
    func testTheCardOffersNoFreeTextRow() throws {
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": ["dev", "prod"]],
        ])))
        XCTAssertFalse(form.questions[0].allowsCustomAnswer)
    }

    func testTheHookIsInstalled() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "Elicitation", in: &hooks, matcher: ".*")
        XCTAssertNotNil(hooks["Elicitation"])
    }
}
