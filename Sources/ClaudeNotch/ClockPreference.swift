import Foundation

/// How the user has asked Claude Code to show clock times, honoured by the
/// notch so the two agree.
///
/// Claude Code 2.1.257 added two settings, described in its own binary as:
///
///   `timeFormat`: Clock format for times shown in the UI: "auto" (default),
///   "12-hour", "24-hour", "24-hour-utc", or a strftime pattern such as "%H:%M"
///   `timeZone`: IANA time zone for times shown in the UI, e.g. "UTC"
///   (default: system time zone)
///
/// The app formats plenty of times of day, and someone who has told Claude Code
/// to use 24-hour UTC has said what they want clocks to look like. Ignoring it
/// means the notch and the terminal below it disagree about what time something
/// happened, which is the sort of small wrongness that makes a tool feel
/// untrustworthy.
///
/// Read from the same settings chain as everything else, so a managed policy
/// still wins.
enum ClockPreference {

    struct Settings: Equatable {
        /// Raw value as written, "" when unset. Kept raw rather than parsed
        /// into a case because a strftime pattern is an open set.
        var format: String = ""
        /// IANA identifier, "" when unset.
        var timeZone: String = ""

        var isDefault: Bool { format.isEmpty || format == "auto" }
    }

    /// Reads disk. Call off the main thread.
    ///
    /// Later files win, matching SandboxReader.settingsPaths: user settings
    /// first, then the project's, then managed, so an administrator's choice is
    /// the last word.
    nonisolated static func read(cwd: String = "",
                                 home: String = NSHomeDirectory(),
                                 managedPath: String = SandboxReader.managedSettingsPath) -> Settings {
        var out = Settings()
        for (path, _) in SandboxReader.settingsPaths(cwd: cwd, home: home, managedPath: managedPath) {
            guard let data = FileManager.default.contents(atPath: path),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if let f = root["timeFormat"] as? String, !f.isEmpty { out.format = f }
            if let z = root["timeZone"] as? String, !z.isEmpty { out.timeZone = z }
        }
        return out
    }

    /// A formatter for a time of day that matches the preference.
    ///
    /// nil means "no opinion", and the caller should keep doing whatever it did
    /// before. That is deliberately different from returning a system-default
    /// formatter: the app's existing formatters vary by context, and replacing
    /// them all with one would change unrelated screens.
    nonisolated static func timeFormatter(_ s: Settings) -> DateFormatter? {
        guard !s.isDefault || !s.timeZone.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        switch s.format {
        case "12-hour":
            f.dateFormat = "h:mm a"
        case "24-hour":
            f.dateFormat = "HH:mm"
        case "24-hour-utc":
            f.dateFormat = "HH:mm"
            f.timeZone = TimeZone(identifier: "UTC")
        case "", "auto":
            // No format opinion, but a zone one: keep the locale's own clock
            // and just move it.
            f.locale = Locale.current
            f.timeStyle = .short
            f.dateStyle = .none
        default:
            // A strftime pattern. Translated rather than trusted: DateFormatter
            // speaks Unicode date-field patterns, and handing it "%H:%M" would
            // print a literal percent sign and the letter H.
            guard let converted = strftimeToDateFormat(s.format) else { return nil }
            f.dateFormat = converted
        }
        // An explicit zone wins over the one implied by the format, except for
        // 24-hour-utc, where UTC is the format.
        if !s.timeZone.isEmpty, s.format != "24-hour-utc", let tz = TimeZone(identifier: s.timeZone) {
            f.timeZone = tz
        }
        return f
    }

    /// The handful of strftime fields that appear in a clock, mapped to the
    /// Unicode pattern DateFormatter wants.
    ///
    /// Anything containing a field outside this set returns nil so the caller
    /// falls back, rather than printing a half-translated pattern. A wrong
    /// clock is worse than the default one.
    nonisolated static func strftimeToDateFormat(_ pattern: String) -> String? {
        let map: [Character: String] = [
            "H": "HH",   // 00-23
            "I": "hh",   // 01-12
            "M": "mm",
            "S": "ss",
            "p": "a",
            "y": "yy",
            "Y": "yyyy",
            "m": "MM",
            "d": "dd",
            "e": "d",
            "b": "MMM",
            "B": "MMMM",
            "a": "EEE",
            "A": "EEEE",
            "Z": "zzz",
            "%": "%",
        ]
        var out = ""
        var sawField = false
        var it = pattern.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            guard ch == "%" else {
                // Literal text has to be quoted or DateFormatter reads letters
                // as fields: an unquoted "at" would print an era and a year.
                out += ch.isLetter ? "'\(ch)'" : String(ch)
                continue
            }
            guard let field = it.next(), let replacement = map[field] else { return nil }
            out += replacement
            sawField = true
        }
        return sawField ? out : nil
    }
}
