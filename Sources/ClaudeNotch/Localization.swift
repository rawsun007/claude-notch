import Foundation

/// Which language the notch speaks, and the lookup that honours it.
///
/// macOS normally decides this at launch from the system language list, which
/// means an in-app picker would need a relaunch to take effect. That is a poor
/// trade for a menu-bar app you leave running for days, so the chosen table is
/// resolved per lookup instead: pick a language and the notch changes while you
/// are looking at it.
///
/// `L(_:comment:)` replaces `NSLocalizedString` everywhere for that reason.
/// tools/l10n-extract.py reads the same call shape, so the strings table is
/// still generated from the source.
enum Localization {

    /// UserDefaults key for the override. Empty or absent means follow macOS.
    static let defaultsKey = "ClaudeNotchLanguage"

    /// Guards the cached bundle. Lookups happen from the main actor in views
    /// and off it in Announcer, so this cannot be main-isolated.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedCode: String?
    nonisolated(unsafe) private static var cachedBundle: Bundle?

    /// Language codes shipped in the app bundle, English first, then the rest
    /// alphabetically by their own name.
    nonisolated static var available: [String] {
        let codes = Bundle.main.localizations.filter { $0 != "Base" }
        let rest = codes.filter { $0 != "en" }.sorted {
            (nativeName($0) ?? $0).localizedCaseInsensitiveCompare(nativeName($1) ?? $1) == .orderedAscending
        }
        return (codes.contains("en") ? ["en"] : []) + rest
    }

    /// What speakers of a language call it, which is what belongs in a picker:
    /// someone looking for Japanese is looking for 日本語, not "Japanese".
    nonisolated static func nativeName(_ code: String) -> String? {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The current override, or "" when following the system.
    nonisolated static var languageCode: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            lock.lock()
            cachedCode = nil
            cachedBundle = nil
            lock.unlock()
        }
    }

    /// The table to read from. Nil means the main bundle, which applies the
    /// system's own language preference.
    nonisolated static func overrideBundle() -> Bundle? {
        let code = languageCode
        guard !code.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if cachedCode == code { return cachedBundle }
        cachedCode = code
        cachedBundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        return cachedBundle
    }
}

/// Look up a user-facing string.
///
/// Falls back to the main bundle, and then to the key itself, so a language
/// missing a key reads as English rather than as an empty control.
func L(_ key: String, comment: String = "") -> String {
    if let bundle = Localization.overrideBundle() {
        let translated = bundle.localizedString(forKey: key, value: nil, table: nil)
        if translated != key { return translated }
    }
    return Bundle.main.localizedString(forKey: key, value: key, table: nil)
}
