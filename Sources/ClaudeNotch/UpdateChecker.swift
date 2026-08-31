import Foundation

/// Lightweight update checker. Asks the GitHub Releases API for the latest
/// tag and, if it's newer than the running build, fires `onUpdateAvailable`.
///
/// This notifies; installing is `claudenotch-update.sh`, which the Update Now
/// button runs (see `TerminalAutomator.runUpdater`). Not Sparkle: that would add
/// a framework, an EdDSA key pair and a signed appcast to do what the script
/// already does, and now that releases are notarized the script can check the
/// downloaded bundle against the Developer ID team rather than a checksum alone,
/// which was the part Sparkle would otherwise have been buying us.
final class UpdateChecker: @unchecked Sendable {
    static let shared = UpdateChecker()

    private let repo = ProjectLinks.repo
    let releasesPage = ProjectLinks.latestRelease

    /// Called on the main thread with the new version when an update is found.
    /// `userInitiated` lets the UI decide whether to show a modal alert
    /// (manual "Check for Updates…") or silently update a menu item (daily poll).
    var onUpdateAvailable: ((_ version: String, _ userInitiated: Bool) -> Void)?
    /// Called on the main thread after a user-initiated check that found nothing.
    var onUpToDate: (() -> Void)?
    /// Called on the main thread when a user-initiated check fails (network, etc.).
    var onCheckFailed: (() -> Void)?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Check now, then once a day.
    func start() {
        check()
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func check(userInitiated: Bool = false) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let current = currentVersion

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            var newVersion: String?
            var failed = false
            if let data,
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let latest = Self.version(fromTag: tag)
                if Self.isNewer(latest, than: current) { newVersion = latest }
            } else if error != nil || data == nil {
                failed = true
            }
            DispatchQueue.main.async {
                if let v = newVersion {
                    self.onUpdateAvailable?(v, userInitiated)
                } else if userInitiated {
                    if failed {
                        self.onCheckFailed?()
                    } else {
                        self.onUpToDate?()
                    }
                }
            }
        }.resume()
    }

    /// "v0.15.1" -> "0.15.1". Releases are tagged with the v, versions are not.
    static func version(fromTag tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    /// Compare dotted version strings numerically (e.g. "0.2.10" > "0.2.9").
    ///
    /// Each part is read up to its first non-digit, so "1.2.3-beta" compares as
    /// 1.2.3. A leading v is stripped first: without that, "v1.0.0" read as
    /// 0.0.0 and the app would decide it was already up to date forever. The
    /// caller strips it too, but this is the function that must not be fooled.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            version(fromTag: s).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
