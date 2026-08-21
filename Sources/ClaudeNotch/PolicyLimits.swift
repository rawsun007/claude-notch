import Foundation

// What an organisation has decided this machine's agents may do, and whether
// anyone is watching them.
//
// Claude Code writes ~/.claude/policy-limits.json from managed settings: a set
// of named restrictions, a list of compliance taints, and a monitoring notice.
// Nothing surfaces any of it. On a personal Mac the file is inert. On a
// company Mac it is the answer to the question this app exists for, one level
// up: not "what may this agent do in this project", but "what has someone
// above me already decided, and is this session being recorded".
//
// A monitoring notice in particular is something a person should be told once,
// plainly, rather than discovering later.
//
// Pure and nonisolated: it is a file read, and the shapes it has to survive are
// worth pinning in tests rather than finding on a managed laptop.
enum PolicyLimits: Equatable {

    struct Status: Equatable {
        /// Text an administrator wants shown. Nil on an unmanaged machine.
        var monitoringNotice: String?
        /// Restrictions that are switched OFF, by name, as the file spells them.
        /// Only the denials are kept: a list of everything permitted is not
        /// news, and the point is what this Mac cannot do.
        var denied: [String]
        /// Compliance labels attached to this machine's sessions.
        var taints: [String]

        /// Whether an organisation has actually decided something here.
        ///
        /// Not "are any restrictions off". Every personal Mac has a
        /// policy-limits.json with several of them off, because that file also
        /// carries what a consumer account simply does not include:
        /// remote control, quick web setup, and so on. Reading those as an
        /// administrator's decision told people with no administrator that
        /// their organisation restricts their machine, which is both false and
        /// alarming, and it is what shipped.
        ///
        /// A managed machine is one where somebody wrote something: a
        /// monitoring notice, or a compliance label. Restrictions are then
        /// worth listing as detail, but they are not the evidence.
        var isManaged: Bool { monitoringNotice != nil || !taints.isEmpty }
    }

    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/policy-limits.json")
    }

    nonisolated static func read(path: String = defaultPath) -> Status {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Status(monitoringNotice: nil, denied: [], taints: []) }
        return parse(obj)
    }

    nonisolated static func parse(_ obj: [String: Any]) -> Status {
        // {"restrictions": {"allow_remote_control": {"allowed": false}, ...}}
        var denied: [String] = []
        if let restrictions = obj["restrictions"] as? [String: Any] {
            for name in restrictions.keys.sorted() {
                let allowed: Bool? = {
                    if let inner = restrictions[name] as? [String: Any] { return inner["allowed"] as? Bool }
                    return restrictions[name] as? Bool
                }()
                // An entry the app cannot read is not a denial. Saying a machine
                // is restricted when it is not is the same size of mistake as
                // missing a restriction, and this one is easier to make.
                if allowed == false { denied.append(name) }
            }
        }
        let notice = (obj["monitoring_notice"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let taints = ((obj["compliance_taints"] as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
        return Status(monitoringNotice: notice, denied: denied, taints: taints)
    }

    /// A restriction name as a person would say it. The file uses the CLI's own
    /// setting keys, which are readable but not sentences.
    nonisolated static func label(for name: String) -> String {
        switch name {
        case "allow_remote_control":
            return L("Remote control is switched off",
                     comment: "Policy restriction: controlling this Mac's sessions from another device")
        case "allow_quick_web_setup":
            return L("Quick web setup is switched off",
                     comment: "Policy restriction: setting up integrations from the web")
        case "enforce_web_search_mcp_isolation":
            return L("Web search and MCP servers are kept isolated",
                     comment: "Policy restriction: isolation between web search and MCP servers")
        default:
            // Unknown keys still read as something: allow_foo_bar -> "Foo bar".
            let words = name
                .replacingOccurrences(of: "allow_", with: "")
                .replacingOccurrences(of: "enforce_", with: "")
                .split(separator: "_")
                .joined(separator: " ")
            return words.isEmpty ? name : words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// The card raised once when a machine turns out to be managed.
    nonisolated static func cardTitle(_ status: Status) -> String {
        status.monitoringNotice != nil
            ? L("Your organisation has a notice about this session",
                comment: "Card title when managed settings carry a monitoring notice")
            : L("Your organisation has labelled these sessions",
                comment: "Card title when managed settings carry compliance labels but no notice text")
    }

    nonisolated static func cardDetail(_ status: Status) -> String {
        if let notice = status.monitoringNotice { return notice }
        return String(format: L("Sessions on this Mac carry: %@",
                                comment: "Card body listing compliance labels. %@ is a list of labels"),
                      status.taints.joined(separator: ", "))
    }
}
