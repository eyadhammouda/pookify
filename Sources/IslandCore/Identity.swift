import Foundation

/// Stable identity + on-disk locations shared by the hook helper and the app.
///
/// Everything the app touches lives under one Application Support directory, so it is easy
/// to inspect, back up, and fully remove. Nothing here is secret; these are just paths.
public enum Island {
    /// Bundle identifier of the app (used by the helper to `open -g -b` it on session start).
    public static let bundleID = "com.pookify.app"

    /// Human-facing app name.
    public static let appName = "Pookify"

    /// Mach-O executable name inside the bundle.
    public static let executableName = "Pookify"

    /// Name of the compiled hook helper.
    public static let helperName = "island-hook"

    /// Schema version stamped into each state file. Informational/diagnostic only: the reader is
    /// field-tolerant (`SessionSnapshot.init(from:)` decodes every field defensively and ignores
    /// unknown ones), so it is not gated on this number.
    public static let stateSchema = 1

    /// `~/Library/Application Support/Pookify`. ISLAND_SUPPORT_DIR overrides it (dev/tests only —
    /// lets a test app instance run against an isolated state world instead of the real one).
    public static var supportDir: URL {
        if let p = ProcessInfo.processInfo.environment["ISLAND_SUPPORT_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Pookify", isDirectory: true)
    }

    /// `.../state.d` — one JSON file per live session, the unit of state and the liveness marker.
    public static var stateDir: URL { supportDir.appendingPathComponent("state.d", isDirectory: true) }

    /// `.../bin` — where the app copies the helper so hook commands point at a stable path
    /// (survives app updates / moving the .app around).
    public static var binDir: URL { supportDir.appendingPathComponent("bin", isDirectory: true) }

    /// Installed location of the hook helper.
    public static var installedHelper: URL { binDir.appendingPathComponent(helperName) }

    /// Debug log (only written when ISLAND_DEBUG=1).
    public static var debugLog: URL { supportDir.appendingPathComponent("hooks.log") }

    /// PID of the running app (written on launch, removed on a clean quit). The hook helper
    /// checks it with kill(pid, 0) so any session activity can relaunch the app after it
    /// self-quit; the app itself checks it on launch so only one instance owns the notch.
    public static var appPidFile: URL { supportDir.appendingPathComponent("app.pid") }

    public static func ensureDirs() {
        // Owner-only (0700): the state files record the absolute cwd / project / model of each
        // session, so keep them out of reach of other local users on a shared machine.
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        let fm = FileManager.default
        for dir in [supportDir, stateDir, binDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attrs)
            // createDirectory only applies attributes to dirs it creates; tighten an existing one too.
            try? fm.setAttributes(attrs, ofItemAtPath: dir.path)
        }
    }
}
