import Foundation

/// Strip credentials out of a command before it is shown, spoken, stored or
/// exported.
///
/// A tool call arrives as text and is put on a card, and agents put secrets in
/// commands all the time: `export STRIPE_KEY=sk_live_…`, a bearer token in a
/// curl header, a password in a database URL. That one string used to reach the
/// notch card, a macOS notification (Notification Center, and the lock screen
/// depending on Show Previews), `~/.claudenotch/state.json` where it sat for
/// five hundred entries, and the CSV export people paste into tickets. None of
/// those needed the secret to do their job.
///
/// Two rules shape everything here.
///
/// **Keep the command readable.** The card exists so someone can decide whether
/// to allow a command, and a wall of `[redacted]` cannot be judged. Where a
/// secret is a *value*, the name is kept and only the value goes, so
/// `--token abc123` reads as `--token [redacted]`.
///
/// **Redact at the sinks, never at the source.** `PermissionRequest.detail`
/// stays exactly as the agent sent it, because "always allow this exact
/// command" is built from it: a rule stored against a redacted command would
/// match every other command sharing its shape, which is a far worse bug than
/// the one being fixed. Redaction happens where the text is displayed, spoken,
/// persisted or exported.
///
/// Missing a secret is a bug worth fixing; mangling a harmless command is a bug
/// too, and the second one costs more, because it makes the approval decision
/// impossible. Where the two conflict, the patterns stay narrow.
enum SecretRedactor {

    static let placeholder = "[redacted]"

    /// Formats that are unmistakable on sight, so the whole match goes. Lengths
    /// are on the generous side of what each vendor issues, to keep a literal
    /// like `sk-test` or a branch named `ghp_experiment` out of it.
    private static let tokenPatterns: [String] = [
        #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#,                                    // Anthropic
        #"\bsk-proj-[A-Za-z0-9_\-]{20,}"#,                                   // OpenAI project
        #"\bsk-[A-Za-z0-9]{32,}"#,                                           // OpenAI classic
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,                                    // GitHub
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,                                  // GitHub fine-grained
        // GitLab issues a family of prefixed tokens, not just personal access
        // tokens. Claude Code learned the rest of them in 2.1.232; a history
        // entry outlives the session it appeared in (it is persisted, and every
        // export is built from it), so the ones it did not know were the ones
        // that stayed on disk.
        #"\bglpat-[A-Za-z0-9_\-]{16,}"#,                                     // personal access
        #"\bgldt-[A-Za-z0-9_\-]{16,}"#,                                      // deploy
        #"\bglrt-[A-Za-z0-9_\-]{16,}"#,                                      // runner
        #"\bgloas-[A-Za-z0-9_\-]{16,}"#,                                     // OAuth application secret
        #"\bglptt-[A-Za-z0-9_\-]{16,}"#,                                     // pipeline trigger
        #"\bglagent-[A-Za-z0-9_\-]{16,}"#,                                   // agent
        #"\bglimt-[A-Za-z0-9_\-]{16,}"#,                                     // incoming mail
        #"\bglsoat-[A-Za-z0-9_\-]{16,}"#,                                    // scim oauth
        #"\bglcbt-[A-Za-z0-9_\-]{16,}"#,                                     // cluster agent
        #"\bglft-[A-Za-z0-9_\-]{16,}"#,                                      // feature flags client
        #"\bglffct-[A-Za-z0-9_\-]{16,}"#,                                    // feature flags unleash
        #"\b[sr]k_(live|test)_[A-Za-z0-9]{16,}"#,                            // Stripe
        #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,                                     // AWS access key id
        #"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#,                                 // Slack
        #"\bAIza[0-9A-Za-z_\-]{35}"#,                                        // Google API key
        #"\bnpm_[A-Za-z0-9]{36}"#,                                           // npm
        #"\bhf_[A-Za-z0-9]{34,}"#,                                           // Hugging Face
        #"\bdop_v1_[A-Za-z0-9]{60,}"#,                                       // DigitalOcean
        #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, // JWT
    ]

    /// A private key block, however long. Matched separately because it spans
    /// lines and the whole body has to go, not just the header.
    private static let privateKeyBlock =
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#

    /// Patterns where group 1 names the thing and the rest is the secret. The
    /// template rebuilds the name and replaces the value, so the reader still
    /// sees which credential is in play without seeing it.
    /// The words in a variable name that mean its value is a credential. Bare
    /// AUTH is deliberately absent: `AUTH_MODE=oauth` is not a secret, and
    /// `AUTH_TOKEN` is already covered by TOKEN.
    private static let secretWords =
        "SECRET|TOKEN|PASSWORD|PASSWD|APIKEY|API_KEY|ACCESSKEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|CREDENTIALS"

    /// Flag names whose next argument is a credential.
    private static let secretFlags = "token|password|passwd|api-?key|access-?key|secret"

    private static let valuePatterns: [(pattern: String, template: String, caseInsensitive: Bool)] = [
        // NAME='value with spaces'. Ahead of the unquoted form, which stops at
        // the first space and so would leave the rest of the secret in place.
        (#"\b([A-Za-z0-9_]*(?:\#(secretWords))[A-Za-z0-9_]*\s*=\s*)(['"])([^'"]*)\2"#,
         "$1$2\(placeholder)$2", true),

        // NAME=value.
        (#"\b([A-Za-z0-9_]*(?:\#(secretWords))[A-Za-z0-9_]*\s*=\s*)([^\s'"]+)"#,
         "$1\(placeholder)", true),

        // --token value, --password=value, --with-token value.
        //
        // The leading boundary is matched explicitly rather than with \b: a \b
        // before `--` never fires, because a space and a dash are both
        // non-word, so this whole rule silently did nothing for the ordinary
        // ` --token x` and only caught ` --with-token x` by accident, through
        // the word boundary inside it.
        //
        // The separator must be an equals or whitespace, which is what keeps
        // `docker login --password-stdin` untouched.
        (#"((?:^|[\s;|&(])--?(?:[A-Za-z0-9]+-)?(?:\#(secretFlags))(?:=|\s+))(\S+)"#,
         "$1\(placeholder)", true),

        // Authorization: Bearer …, and the Basic / Token schemes beside it.
        (#"\b((?:Bearer|Basic|Token)\s+)([A-Za-z0-9\-._~+/=]{12,})"#,
         "$1\(placeholder)", false),

        // The password in a connection string: postgres://user:pw@host.
        (#"(://[^/\s:@]+:)([^/\s@]+)(@)"#,
         "$1\(placeholder)$3", false),
    ]

    /// Redact `s`. Pure, so the classification is testable without a UI.
    ///
    /// Runs oldest-to-newest: the private key block first (it can contain
    /// anything), then whole-token formats, then value patterns. Order matters
    /// only in that a token already replaced cannot be matched again.
    static func redact(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = replace(s, pattern: privateKeyBlock, template: placeholder, caseInsensitive: false)
        for pattern in tokenPatterns {
            out = replace(out, pattern: pattern, template: placeholder, caseInsensitive: false)
        }
        for (pattern, template, ci) in valuePatterns {
            out = replace(out, pattern: pattern, template: template, caseInsensitive: ci)
        }
        return out
    }

    /// True when redacting would change the string. Lets a caller say "this
    /// card hides a credential" without diffing two strings itself.
    static func containsSecret(_ s: String) -> Bool {
        redact(s) != s
    }

    private static func replace(_ input: String, pattern: String,
                                template: String, caseInsensitive: Bool) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }
}
