import Foundation

/// The app's own name, as the bundle declares it.
///
/// Hardcoding it meant the display name lived in two dozen string literals and
/// in Info.plist, so renaming the app renamed some of it. Reading the bundle
/// means the plist is the only place it is written down, and a build that
/// changes CFBundleDisplayName changes every mention of it at once.
///
/// The fallback matters for tests and for the SPM executable, neither of which
/// has an Info.plist at all: a nil display name there would render UI with a
/// hole in it rather than a name.
enum AppInfo {
    static let displayName: String = {
        let bundle = Bundle.main
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ""
        return name.isEmpty ? "ClaudeNotch" : name
    }()
}
