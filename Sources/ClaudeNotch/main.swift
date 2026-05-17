import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
