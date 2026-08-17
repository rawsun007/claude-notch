import Foundation

// MCP elicitation: a server asking the user something in the middle of a tool
// call ("which environment?", "may I overwrite this?").
//
// Claude Code 2.1.76 added the `Elicitation` hook, which fires before its own
// dialog and lets a hook answer on the user's behalf. That is the same shape
// as the AskUserQuestion card the notch already shows, so the question can be
// answered in the notch instead of in a terminal the user is not looking at.
//
// The schema an MCP server may send is deliberately narrow (flat primitive
// properties only), but it is still wider than a card of buttons can answer
// honestly. Booleans and string enums are a fixed set of choices, so they map
// onto the card exactly. Free text and numbers do not, and rather than invent
// a text field whose validation this app does not own, those are left to
// Claude Code's own dialog: the hook simply declines to answer.
//
// Pure and `nonisolated`: the payload is untrusted input, so its handling is
// decided by tests.
enum ElicitationParser {

    // An MCP server is a third-party program the user installed, and everything
    // below arrives from it. Every other payload-fed collection in this app is
    // capped; this one was not.
    //
    // Past a cap the elicitation is declined rather than truncated. A truncated
    // question is a question the user did not read, and the answer would go
    // back to the server as if they had.

    /// Enough for a sentence or two of context.
    static let maxMessage = 300
    /// A field label is a few words.
    static let maxTitle = 80
    /// And its explanation a line.
    static let maxDescription = 200
    /// A choice you can read on a card in a notch.
    static let maxOptionLabel = 60
    /// More than this is a list, not a set of buttons.
    static let maxOptions = 12
    /// A form is a card, not a page.
    static let maxFields = 6

    /// One answerable field of a requested schema.
    struct Field: Equatable {
        let name: String            // the property key the answer goes back under
        let title: String           // what to show; falls back to the key
        let description: String
        let options: [String]       // the choices, in the order they are shown
        let isBoolean: Bool         // choices are yes/no, so the answer is a Bool
    }

    /// An elicitation the notch can actually answer.
    struct Form: Equatable {
        let serverName: String
        let message: String
        let fields: [Field]

        var questions: [AskQuestion] {
            fields.map { f in
                AskQuestion(header: f.title,
                            text: f.description.isEmpty ? f.title : f.description,
                            multiSelect: false,
                            options: f.options.map { AskOption(label: $0, description: "") },
                            // The options are the whole schema. A typed-in
                            // answer would not satisfy it, so the card must not
                            // offer one.
                            allowsCustomAnswer: false)
            }
        }

        /// Turn the card's answers back into the `content` object the MCP
        /// server asked for. Nil when any field went unanswered: a partial
        /// object fails the server's own required-property check, and guessing
        /// the rest would be answering for the user.
        func content(from answers: [[String]]) -> [String: Any]? {
            guard answers.count == fields.count else { return nil }
            var out: [String: Any] = [:]
            for (field, picks) in zip(fields, answers) {
                guard let pick = picks.first(where: { !$0.isEmpty }) else { return nil }
                if field.isBoolean {
                    out[field.name] = (pick == Self.yes)
                } else {
                    guard field.options.contains(pick) else { return nil }
                    out[field.name] = pick
                }
            }
            return out
        }

        static let yes = "Yes"
        static let no = "No"
    }

    /// Build a form from an `Elicitation` hook payload, or nil when this
    /// elicitation is not one the notch should answer.
    ///
    /// Nil for: a URL-mode elicitation (the answer is a browser flow, not a
    /// choice), an empty schema, and any schema with a property the card
    /// cannot represent. Nil means "no opinion" — the caller replies with a
    /// bare OK and Claude Code asks in the terminal exactly as it would have.
    nonisolated static func form(from payload: [String: Any]) -> Form? {
        // "url" mode sends the user to a browser to authenticate. There is
        // nothing to pick, and the notch must not open a payload-supplied URL.
        let mode = (payload["mode"] as? String) ?? ""
        guard mode != "url" else { return nil }

        guard let schema = payload["requested_schema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              !properties.isEmpty
        else { return nil }

        // JSON objects arrive unordered, so the order is chosen rather than
        // preserved: required fields first (they are what blocks the server),
        // then alphabetically, so the same schema always draws the same card.
        let required = Set((schema["required"] as? [String])?.compactMap { $0 } ?? [])
        let keys = properties.keys.sorted { a, b in
            let ra = required.contains(a), rb = required.contains(b)
            if ra != rb { return ra }
            return a < b
        }

        guard keys.count <= maxFields else { return nil }

        var fields: [Field] = []
        for key in keys {
            guard let spec = properties[key] as? [String: Any],
                  let field = self.field(name: key, spec: spec)
            else { return nil }   // one unanswerable field makes the whole form unanswerable
            fields.append(field)
        }

        let message = (payload["message"] as? String) ?? ""
        guard message.count <= maxMessage else { return nil }

        return Form(serverName: String(((payload["mcp_server_name"] as? String) ?? "").prefix(maxTitle)),
                    message: message,
                    fields: fields)
    }

    /// One property of the schema, or nil when it is not a fixed set of
    /// choices.
    nonisolated static func field(name: String, spec: [String: Any]) -> Field? {
        let title = (spec["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let description = (spec["description"] as? String) ?? ""
        let type = (spec["type"] as? String) ?? ""

        // A label longer than the card is a label nobody read, and the answer
        // would go back as if they had. Refuse rather than cut.
        guard title.count <= maxTitle, description.count <= maxDescription,
              name.count <= maxTitle
        else { return nil }

        if type == "boolean" {
            return Field(name: name, title: title, description: description,
                         options: [Form.yes, Form.no], isBoolean: true)
        }
        // A string with an enum is a menu. A string without one is free text,
        // which this card cannot ask for.
        if type == "string", let cases = spec["enum"] as? [Any] {
            let options = cases.compactMap { $0 as? String }.filter { !$0.isEmpty }
            guard options.count == cases.count, !options.isEmpty,
                  options.count <= maxOptions,
                  options.allSatisfy({ $0.count <= maxOptionLabel })
            else { return nil }
            return Field(name: name, title: title, description: description,
                         options: options, isBoolean: false)
        }
        return nil
    }
}
