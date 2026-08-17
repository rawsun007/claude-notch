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

    // MARK: - Caps

    /// An MCP server is a third-party program. Past a cap the elicitation is
    /// declined rather than truncated: a question the user could not read is
    /// not a question they answered.
    func testAnOversizeMessageIsDeclined() {
        var p = payload(properties: ["ok": ["type": "boolean"]])
        p["message"] = String(repeating: "x", count: ElicitationParser.maxMessage + 1)
        XCTAssertNil(ElicitationParser.form(from: p))

        p["message"] = String(repeating: "x", count: ElicitationParser.maxMessage)
        XCTAssertNotNil(ElicitationParser.form(from: p))
    }

    func testAnOversizeTitleOrDescriptionIsDeclined() {
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "ok": ["type": "boolean", "title": String(repeating: "t", count: ElicitationParser.maxTitle + 1)],
        ])))
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "ok": ["type": "boolean", "description": String(repeating: "d", count: ElicitationParser.maxDescription + 1)],
        ])))
    }

    /// A property name stands in as the label when there is no title, so it is
    /// bounded by the same rule.
    func testAnOversizePropertyNameIsDeclined() {
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            String(repeating: "n", count: ElicitationParser.maxTitle + 1): ["type": "boolean"],
        ])))
    }

    func testTooManyOptionsIsDeclined() {
        let many = (0...ElicitationParser.maxOptions).map { "opt\($0)" }
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": many],
        ])))
        XCTAssertNotNil(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": Array(many.prefix(ElicitationParser.maxOptions))],
        ])))
    }

    func testAnOversizeOptionLabelIsDeclined() {
        XCTAssertNil(ElicitationParser.form(from: payload(properties: [
            "env": ["type": "string", "enum": ["dev", String(repeating: "p", count: ElicitationParser.maxOptionLabel + 1)]],
        ])))
    }

    func testTooManyFieldsIsDeclined() {
        var props: [String: Any] = [:]
        for i in 0...ElicitationParser.maxFields { props["f\(i)"] = ["type": "boolean"] }
        XCTAssertNil(ElicitationParser.form(from: payload(properties: props)))
    }

    /// A form at every limit exactly is still answered: the caps are a ceiling,
    /// not a margin.
    func testAFormAtTheLimitsIsAccepted() throws {
        var props: [String: Any] = [:]
        for i in 0..<ElicitationParser.maxFields {
            props["f\(i)"] = [
                "type": "string",
                "title": String(repeating: "t", count: ElicitationParser.maxTitle),
                "description": String(repeating: "d", count: ElicitationParser.maxDescription),
                "enum": (0..<ElicitationParser.maxOptions).map { _ in UUID().uuidString.prefix(ElicitationParser.maxOptionLabel) }.map(String.init),
            ]
        }
        let form = try XCTUnwrap(ElicitationParser.form(from: payload(properties: props)))
        XCTAssertEqual(form.fields.count, ElicitationParser.maxFields)
    }

    // MARK: - Ending somewhere else

    @MainActor
    private func queued(id: String, into state: AppState) -> Int {
        var cancelled = 0
        state.enqueueQuestion(QuestionRequest(
            questions: [AskQuestion(header: "Environment", text: "Where?",
                                    multiSelect: false,
                                    options: [AskOption(label: "dev", description: "")],
                                    allowsCustomAnswer: false)],
            source: "deploy-tools", cwd: "/tmp/proj", elicitationId: id,
            resolver: { if $0 == nil { cancelled += 1 } }))
        return cancelled
    }

    /// Cancelled in the terminal, interrupted, answered elsewhere: the card
    /// goes, and the blocked hook connection is released with a cancel.
    @MainActor
    func testTheResultTakesTheCardDown() {
        let state = AppState()
        var cancelled = 0
        state.enqueueQuestion(QuestionRequest(
            questions: [AskQuestion(header: "Environment", text: "Where?", multiSelect: false,
                                    options: [AskOption(label: "dev", description: "")])],
            source: "deploy-tools", cwd: "/tmp/proj", elicitationId: "e1",
            resolver: { if $0 == nil { cancelled += 1 } }))
        state.dismissElicitation(id: "e1")
        XCTAssertTrue(state.questionQueue.isEmpty)
        XCTAssertEqual(cancelled, 1)
    }

    /// Another server's elicitation, and Claude's own questions, stay up.
    @MainActor
    func testOnlyTheMatchingCardGoes() {
        let state = AppState()
        _ = queued(id: "e1", into: state)
        _ = queued(id: "e2", into: state)
        state.enqueueQuestion(QuestionRequest(
            questions: [AskQuestion(header: "H", text: "Q", multiSelect: false,
                                    options: [AskOption(label: "a", description: "")])],
            source: "Claude Code", cwd: "/tmp/proj", resolver: { _ in }))
        state.dismissElicitation(id: "e1")
        XCTAssertEqual(state.questionQueue.count, 2)
        XCTAssertEqual(state.questionQueue.map(\.elicitationId), ["e2", ""])
    }

    /// An empty id must never match the AskUserQuestion cards, which all have
    /// one.
    @MainActor
    func testAnEmptyIdDismissesNothing() {
        let state = AppState()
        _ = queued(id: "", into: state)
        state.dismissElicitation(id: "")
        XCTAssertEqual(state.questionQueue.count, 1)
    }

    func testTheHooksAreInstalled() {
        var hooks: [String: Any] = [:]
        HookInstaller.appendHook(to: "Elicitation", in: &hooks, matcher: ".*")
        HookInstaller.appendHook(to: "ElicitationResult", in: &hooks, matcher: ".*")
        XCTAssertNotNil(hooks["Elicitation"])
        XCTAssertNotNil(hooks["ElicitationResult"])
    }
}
