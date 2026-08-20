import Foundation

// A shared secret between Claude Code's hooks and this app.
//
// What it is for, stated honestly, because it is easy to oversell.
//
// The hook port accepts anything that can reach loopback. The browser and
// DNS-rebinding gate keeps web pages out, and the socket is bound to the
// loopback addresses so nothing off the machine can try. What remains is every
// other process running on the Mac: any of them can post a hook payload, which
// means inventing a session, faking activity, or putting a card in front of the
// user that looks like it came from Claude and reading whatever they answer.
//
// A token in the hook URL fixes the accidental and the lazy version of that.
// It does not fix the determined version: the URL lives in settings.json, and a
// process running as you can read that file exactly as this app does. Anyone
// claiming otherwise is selling something. What it buys is real but bounded:
// another account on the same Mac cannot post hooks, a program that has not
// gone looking for the token cannot either, and a payload arriving without one
// is now a fact the app can notice rather than a normal event.
//
// The failure mode has to be considered before the benefit, because getting it
// wrong makes the app deaf, which is worse than anything above. So: the token
// is required only when the app can see one in its own installed hook URLs. An
// install that has not been re-run, a settings file the app cannot read, a
// forwarder script that predates all this: all of them keep working exactly as
// before, and the check turns itself on when, and only when, the URL that
// Claude Code is posting to actually carries a token.
enum HookToken {

    /// Where the token itself lives. 0600, next to everything else this app
    /// owns, so another account cannot read it even though it appears in
    /// settings.json too.
    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claudenotch/hook-token")
    }

    /// The query parameter the forwarders put it in.
    static let queryName = "t"

    /// Read the token, or nil when this install has none.
    nonisolated static func read(from path: String = HookToken.path) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Make one if there is not one already, and hand it back.
    ///
    /// Generated from the system's random source, 32 bytes, hex. Long enough
    /// that guessing is not a strategy, short enough to sit in a URL in a
    /// settings file a person might read.
    @discardableResult
    nonisolated static func ensure(at path: String = HookToken.path) -> String? {
        if let existing = read(from: path) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard (try? token.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return token
    }

    /// What the app should demand, read from the hook URL it installed.
    ///
    /// Deliberately not read from the token file. The question is not "does
    /// this machine have a token", it is "does the thing calling us send one",
    /// and only the installed URL answers that. A token file left behind by an
    /// install whose settings were later edited or rolled back would otherwise
    /// make the app demand something nothing sends, which is the one outcome
    /// this feature must never produce.
    nonisolated static func expected(settingsPath: String = HookInstaller.settingsPath) -> String? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return nil }

        // Walked as JSON rather than scanned as text. The first version searched
        // the file for "53127/hook?" and never matched, because Foundation
        // writes the URL with escaped slashes: 127.0.0.1:53127\\/hook. It failed
        // open, so the check simply never engaged, which is the right direction
        // to fail in and the wrong thing to ship.
        for rules in hooks.values {
            guard let rules = rules as? [[String: Any]] else { continue }
            for rule in rules {
                for entry in (rule["hooks"] as? [[String: Any]]) ?? [] {
                    guard let url = entry["url"] as? String, url.contains("53127") else { continue }
                    guard let mark = url.firstIndex(of: "?") else { continue }
                    if let token = inQuery(String(url[url.index(after: mark)...])) { return token }
                }
            }
        }
        return nil
    }

    /// The token in a request's query string, if it carries one.
    ///
    /// Written by hand rather than with URLComponents: this runs on the hook
    /// path for every request, and the input is a raw request line that may not
    /// be a valid URL at all.
    nonisolated static func inQuery(_ query: String?) -> String? {
        guard let query, !query.isEmpty else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(queryName) else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Whether a request may be served.
    ///
    /// `expected` is what the app believes its own hooks are sending, which is
    /// nil for every install that has not been given a token yet. Nil means
    /// accept: an app that starts refusing hooks because of a half-finished
    /// migration is an app that shows nothing, and showing nothing is the
    /// failure this whole feature is not worth causing.
    nonisolated static func allows(query: String?, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let offered = inQuery(query) else { return false }
        return constantTimeEquals(offered, expected)
    }

    /// Compare without leaking where two tokens diverge. The attacker here is
    /// local and could read the file instead, so this is closer to hygiene than
    /// to necessity, and it costs nothing.
    nonisolated static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}
