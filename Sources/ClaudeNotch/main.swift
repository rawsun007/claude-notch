import AppKit

// `ClaudeNotch --install-hooks` runs the installer and exits, without a menu
// bar icon, a window, or a running server.
//
// It exists because the hooks were being merged into settings.json by two
// different programs: this app, in Swift, and install-hooks.sh, in jq. Two
// implementations of one merge drift, and they already had: a fix to the
// backup rules landed in the Swift copy while the shell copy went on doing the
// old thing, because the shell copy is the one that actually runs during setup.
//
// Now the shell script asks the app to do it whenever the app is on disk, which
// is every case except a machine that has not installed it yet, and there is
// one merge again.
if CommandLine.arguments.contains("--install-hooks") {
    do {
        try HookInstaller.install()
        print("ClaudeNotch: hooks installed")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("ClaudeNotch: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
