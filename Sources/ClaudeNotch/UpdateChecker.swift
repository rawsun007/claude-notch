import Foundation

/// Lightweight update checker. Asks the GitHub Releases API for the latest
/// tag and, if it's newer than the running build, fires `onUpdateAvailable`.
///
/// This is a notify-and-link updater (it opens the releases page / DMG), not a
/// silent in-place updater — that would need Sparkle, signing keys, a signed
/// appcast, and ideally notarization. For an ad-hoc-signed app whose first
/// launch is manual anyway, notify-and-link is the pragmatic choice.
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
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
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

    /// Compare dotted version strings numerically (e.g. "0.2.10" > "0.2.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
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
