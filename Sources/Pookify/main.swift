import AppKit
import IslandCore

// Headless management commands, so the install/uninstall scripts can wire hooks without opening
// the UI:  Pookify --install  /  --uninstall
let argv = CommandLine.arguments
if argv.contains("--uninstall") {
    HookInstaller.uninstall()
    print("Removed Pookify hooks from Claude Code.")
    exit(0)
}
if argv.contains("--install") {
    let wired = HookInstaller.installAll()
    if wired.isEmpty {
        print("No Claude Code config found to wire up.")
    } else {
        print("Wired Pookify into:\n" + wired.map { "  • \($0)" }.joined(separator: "\n"))
    }
    exit(0)
}

// Pookify — background agent (no Dock icon, no menu bar item). UI lives entirely
// on the notch. We drive the app from an AppDelegate rather than the SwiftUI App lifecycle so it
// behaves correctly when built as a bare SwiftPM executable wrapped in a hand-assembled bundle.
//
// Program start is already on the main thread (the main actor's executor), so assumeIsolated lets
// us construct the main-actor controller and run the app loop without a concurrency error.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
