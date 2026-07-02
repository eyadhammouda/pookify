import Foundation

/// Reads and writes the per-session state files in `~/Library/Application Support/Pookify/state.d`.
///
/// Writes are atomic (write to a temp file, then rename) so the app's poller never reads a
/// half-written file. The file name is `<provider>-<sanitized session id>.json`.
public enum StateStore {

    /// Restrict the session id to filename-safe characters so it can't escape the directory.
    public static func safeID(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { scalar -> Character in
            let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
            return ok.contains(scalar) ? Character(scalar) : "_"
        }
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    public static func fileName(provider: Provider, sessionId: String) -> String {
        "\(provider.rawValue)-\(safeID(sessionId)).json"
    }

    public static func fileURL(provider: Provider, sessionId: String) -> URL {
        Island.stateDir.appendingPathComponent(fileName(provider: provider, sessionId: sessionId))
    }

    /// Atomically write a snapshot. Best-effort: never throws (a hook must not fail the session).
    public static func write(_ snapshot: SessionSnapshot) {
        Island.ensureDirs()
        let url = fileURL(provider: snapshot.provider, sessionId: snapshot.sessionId)
        let encoder = JSONEncoder()
        // Pretty-printed + sorted so the files are genuinely human-readable (they're meant to be
        // inspectable via "Show state in Finder").
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        let fm = FileManager.default
        // Owner-only: the snapshot records the session's absolute cwd / project / model.
        let perms: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? fm.setAttributes(perms, ofItemAtPath: tmp.path)
            // Replace any existing file with the temp (atomic rename within the same dir).
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            try? fm.setAttributes(perms, ofItemAtPath: url.path)
        } catch {
            // Fall back to a plain atomic write if replaceItemAt fails (e.g. no existing file).
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes(perms, ofItemAtPath: url.path)
            try? fm.removeItem(at: tmp)
        }
    }

    public static func remove(provider: Provider, sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(provider: provider, sessionId: sessionId))
    }

    /// All current state files (ignores in-flight `.tmp` files).
    public static func listFiles() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Island.stateDir,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == "json" }
    }

    public static func read(_ url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Remove every state file (used on a fresh start when the app wasn't running, so stale
    /// files from a prior crash don't inflate the count).
    public static func clearAll() {
        for url in listFiles() { try? FileManager.default.removeItem(at: url) }
    }
}
