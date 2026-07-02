// swift-tools-version: 6.0
import PackageDescription

// Pookify — a Dynamic-Island-style status indicator for the macOS
// notch that shows the live status of Claude Code sessions.
//
// Pure SwiftPM, system frameworks only (AppKit/SwiftUI). No external dependencies, so it
// builds offline and links into a single binary. Language mode 5 keeps the AppKit-heavy,
// main-actor UI code free of Swift 6 strict-concurrency churn.
let package = Package(
    name: "Pookify",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared types + on-disk state schema used by both the helper and the app.
        .target(
            name: "IslandCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tiny CLI the AI tools' hooks invoke; maps an event to a per-session state file.
        .executableTarget(
            name: "island-hook",
            dependencies: ["IslandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu/notch app itself.
        .executableTarget(
            name: "Pookify",
            dependencies: ["IslandCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
