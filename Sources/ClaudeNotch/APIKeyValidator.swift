import Foundation

/// Checks whether ANTHROPIC_API_KEY looks right and, on demand, whether
/// Anthropic's API actually accepts it. Never logs, persists, or displays the
/// key itself, only its shape and a masked tail, so a debug log or a
/// screenshot of Settings can never leak it.
enum APIKeyValidator {
    enum Result: Equatable {
        case valid
        case invalid(String)      // human-readable reason
        case networkError(String)
    }

    /// The key ClaudeNotch's own process sees, or nil. Best-effort: a process
    /// launched by Finder/launchd does not inherit a Terminal's exported
    /// variables, so a key set only in the user's shell profile will not show
    /// up here even though Claude Code sees it fine when launched from that
    /// same shell. Absence here is not evidence the user has no key.
    static var envKey: String? {
        let v = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// Enough of the key to recognise it without showing it.
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: 8) }
        return "sk-ant-…\(key.suffix(4))"
    }

    /// Shape check only, no network: Anthropic's keys start `sk-ant-` and run
    /// well past what a typo or a placeholder would produce.
    static func looksValid(_ key: String) -> Bool {
        key.hasPrefix("sk-ant-") && key.count >= 20
    }

    /// Turn an HTTP status from a lightweight authenticated call into a
    /// verdict. Pure, so the mapping is testable without a network call.
    /// 429 (rate limited) still means the key was accepted — Anthropic checks
    /// auth before rate limits — so it reads as valid, just busy.
    static func interpret(statusCode: Int) -> Result {
        switch statusCode {
        case 200..<300, 429: return .valid
        case 401: return .invalid("Anthropic rejected this key (401 Unauthorized).")
        case 403: return .invalid("This key does not have access (403 Forbidden).")
        default: return .networkError("Unexpected response (\(statusCode)).")
        }
    }

    /// One cheap authenticated call, just to see whether the key is accepted.
    /// GET /v1/models lists nothing sensitive and costs no tokens.
    static func checkLive(_ key: String) async -> Result {
        guard looksValid(key) else { return .invalid("Doesn't look like an Anthropic API key.") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .networkError("No response.") }
            return interpret(statusCode: http.statusCode)
        } catch {
            return .networkError(error.localizedDescription)
        }
    }
}
