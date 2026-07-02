import Foundation
import IslandCore

/// Wires the island into the AI tools by merging hook entries into their config files, pointing
/// each hook at our compiled helper. Idempotent (re-running strips our old entries first), never
/// clobbers other hooks, and backs up each file once before the first edit. Fully reversible
/// via `uninstall()`.
enum HookInstaller {

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    static var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }

    // event name in the tool  ->  token we pass to island-hook
    static let claudeEvents: [(String, String)] = [
        ("SessionStart", "session-start"),
        ("UserPromptSubmit", "prompt"),
        ("PreToolUse", "pre"),
        ("PostToolUse", "post"),
        ("PostToolUseFailure", "post-fail"),
        ("PermissionRequest", "permission"),
        ("PermissionDenied", "denied"),
        ("Notification", "notify"),
        ("SubagentStart", "subagent-start"),
        ("SubagentStop", "subagent-stop"),
        ("PreCompact", "compact"),
        ("Stop", "stop"),
        ("StopFailure", "stop-fail"),
        ("SessionEnd", "session-end"),
    ]

    // MARK: helper install

    /// Locate the helper shipped next to this executable (Contents/MacOS in a bundle, or the
    /// build dir during development).
    static var bundledHelper: URL {
        let exeDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
        return exeDir.appendingPathComponent(Island.helperName)
    }

    /// Copy the helper to the stable support-dir location so hook commands survive app updates
    /// and the .app being moved. Returns the path hooks should call.
    @discardableResult
    static func installHelper() -> String {
        Island.ensureDirs()
        let dest = Island.installedHelper
        let src = bundledHelper
        let fm = FileManager.default
        if fm.fileExists(atPath: src.path) {
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: src, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                return dest.path
            } catch {
                NSLog("Pookify: could not copy the hook helper to \(dest.path): \(error.localizedDescription).")
                // fall through to whatever stable copy already exists, or (last resort) the bundle.
            }
        }
        if fm.fileExists(atPath: dest.path) { return dest.path }
        // Last resort: wire hooks to the in-bundle helper. This works until the .app is moved, so
        // warn rather than fail silently — the hook command would then point at a stale path.
        NSLog("Pookify: hook helper not installed to its stable location; falling back to the in-bundle path \(src.path), which breaks if the app is moved.")
        return src.path
    }

    // MARK: install / uninstall

    @discardableResult
    static func installAll() -> [String] {
        let helperPath = installHelper()
        let fm = FileManager.default
        var wired: [String] = []
        // Only wire up Claude Code if its config directory already exists, so we never create
        // config for (or write into the home of) a tool the user doesn't actually use. Claude
        // Code creates ~/.claude on first run, so "you have the agent" maps to "dir exists".
        if fm.fileExists(atPath: claudeDir.path) {
            if mergeFile(at: claudeSettings, provider: .claude, events: claudeEvents, helperPath: helperPath) {
                wired.append("Claude Code (~/.claude/settings.json)")
            }
        }
        return wired
    }

    static func uninstall() {
        _ = stripFile(at: claudeSettings)
        // Remove our state + bin (leave backups in place for safety).
        try? FileManager.default.removeItem(at: Island.stateDir)
        try? FileManager.default.removeItem(at: Island.binDir)
    }

    /// Re-run on first launch and whenever the app version changes, so upgrades pick up hook
    /// changes. Returns the list of wired targets if it ran.
    @discardableResult
    static func ensureInstalledIfNeeded() -> [String]? {
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let key = "installedVersion"
        if UserDefaults.standard.string(forKey: key) == current { return nil }
        let wired = installAll()
        UserDefaults.standard.set(current, forKey: key)
        return wired
    }

    // MARK: JSON merge

    /// Wrap a string in single quotes for safe use as one shell word, escaping any embedded single
    /// quote. Robust against spaces, `$`, backticks, quotes, etc. in the (home-derived) helper path.
    private static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func command(helperPath: String, provider: Provider, token: String) -> String {
        // provider.rawValue and token are fixed, known-safe ascii tokens; only the path is dynamic.
        "\(shellSingleQuoted(helperPath)) \(provider.rawValue) \(token)"
    }

    /// Marker that identifies a hook command as ours, so re-installs/uninstalls only touch our entries.
    private static var marker: String { "/Pookify/bin/\(Island.helperName)" }

    /// Merge our hook entries into a JSON file's `hooks` object. Returns true on success.
    @discardableResult
    private static func mergeFile(at url: URL, provider: Provider,
                                  events: [(String, String)], helperPath: String) -> Bool {
        // Distinguish "no config yet" (safe to create) from "config exists but we can't parse it"
        // (NOT safe to overwrite — that would erase the user's real settings). Only a genuinely
        // absent/empty file is treated as an empty object.
        let raw = try? Data(contentsOf: url)
        let parsed = readJSONObject(at: url)
        if let raw, !raw.isEmpty, parsed == nil {
            backupOnce(url)
            NSLog("Pookify: refusing to edit \(url.path) — it isn't a JSON object we can safely merge into. A backup is at \(url.lastPathComponent).bak-pookify; fix the file (or wire the hook manually), then use \"Reinstall hooks\".")
            return false
        }
        backupOnce(url)
        var root = parsed ?? [:]

        // Never silently discard an existing "hooks" value of an unexpected shape.
        if let existing = root["hooks"], !(existing is [String: Any]) {
            NSLog("Pookify: refusing to edit \(url.path) — its \"hooks\" value is not a JSON object.")
            return false
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, token) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = stripOurGroups(groups)
            let cmd = command(helperPath: helperPath, provider: provider, token: token)
            groups.append(["hooks": [["type": "command", "command": cmd]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return writeJSONObject(root, to: url)
    }

    @discardableResult
    private static func stripFile(at url: URL) -> Bool {
        guard var root = readJSONObject(at: url), var hooks = root["hooks"] as? [String: Any] else { return false }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = stripOurGroups(groups)
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return writeJSONObject(root, to: url)
    }

    /// Drop any hook group whose commands all point at our helper; trim ours out of mixed groups.
    private static func stripOurGroups(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            var g = group
            let inner = (g["hooks"] as? [[String: Any]]) ?? []
            let kept = inner.filter { !(($0["command"] as? String ?? "").contains(marker)) }
            if kept.isEmpty { return nil }
            g["hooks"] = kept
            return g
        }
    }

    // MARK: file IO

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func writeJSONObject(_ obj: [String: Any], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var out = data
            out.append(0x0A) // trailing newline
            try out.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    private static func backupOnce(_ url: URL) {
        let bak = url.appendingPathExtension("bak-pookify")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: bak.path) else { return }
        // Never snapshot a file that already contains our hooks — the backup exists to preserve
        // the user's pristine config, and a Pookify-laden copy isn't that. (Happens when the
        // first install created the file, so no backup was taken, and a reinstall runs later.)
        if let s = try? String(contentsOf: url, encoding: .utf8), s.contains(marker) { return }
        try? fm.copyItem(at: url, to: bak)
    }
}
