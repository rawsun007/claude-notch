import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Folder drop onto the notch: provider loading and the drop delegate.



/// Pull file URLs out of the providers a SwiftUI onDrop hands over. Each load is
/// async, so the results are gathered and delivered once on the main actor.
func loadDroppedURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.withLock { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
}

/// The single drop target for the notch. Reports the live drag location so the
/// inner icon box can glow green (`isDropHot`) only when the file is over it,
/// while a drag anywhere over the card opens the black drop panel
/// (`isDropTarget`). One delegate, so no competing drop views flicker the panel.
struct NotchDropDelegate: DropDelegate {
    let state: AppState
    /// The inner icon box, in the drop view's local coordinates (origin top-left).
    let hotRect: CGRect

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }
    func dropEntered(info: DropInfo) {
        guard Date() >= state.suppressHoverUntil else { return }
        setFlags(target: true, hot: hotRect.contains(info.location))
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // After a drop the OS can send a few more enter/update events (the drag
        // image settling), which re-opened the notch as a blue drop panel for a
        // frame — the "notch flickers open a second time" bug. Ignore them during
        // the brief post-drop cooldown.
        guard Date() >= state.suppressHoverUntil else {
            setFlags(target: false, hot: false)
            return DropProposal(operation: .copy)
        }
        setFlags(target: true, hot: hotRect.contains(info.location))
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) {
        setFlags(target: false, hot: false)
    }

    /// dropUpdated fires on every mouse move of the drag — dozens a second.
    /// Writing the same value back into an @Published still publishes, so the
    /// whole notch re-rendered on each event and the drag went sticky. Only
    /// assign on an actual change.
    private func setFlags(target: Bool, hot: Bool) {
        if state.isDropTarget != target { state.isDropTarget = target }
        if state.isDropHot != hot { state.isDropHot = hot }
    }
    func performDrop(info: DropInfo) -> Bool {
        // Clear the cue immediately so the panel collapses now, not after the
        // async URL load returns (which was leaving it stuck green). Start the
        // cooldown here (synchronously at release), so trailing enter/update
        // events can't re-open the panel before the async handleDrop runs.
        state.isDropTarget = false
        state.isDropHot = false
        state.suppressHoverUntil = Date().addingTimeInterval(0.7)
        let providers = info.itemProviders(for: [UTType.fileURL])
        loadDroppedURLs(providers) { urls in state.handleDrop(urls: urls) }
        return true
    }
}
