import Foundation
import IslandCore

/// Turns the set of on-disk session files into a single decision about what the island should
/// show. Stateless: it reaps dead sessions, recovers frozen ones, and surfaces the
/// highest-priority live session (a permission request always beats one merely working).
struct IslandDecision {
    var visible: Bool
    var provider: Provider
    var state: AgentState
    var label: String
    var detail: String
    var startedAt: Double
    var liveCount: Int
    var forceExpand: Bool

    static let hidden = IslandDecision(visible: false, provider: .claude, state: .idle,
                                       label: "", detail: "", startedAt: 0,
                                       liveCount: 0, forceExpand: false)
}

enum SessionAggregator {

    /// How long a transient state stays on screen before the island collapses.
    static let doneLinger: TimeInterval = 2.5
    static let errorLinger: TimeInterval = 3.5
    // Display caps: when a session stops updating (interrupt, closed extension tab) its last
    // state must not stay on screen forever, so a quiet session goes *display-idle* after a
    // while — WITHOUT deleting its file, so a tool that finally reports back (a 10-minute build,
    // a long test run) resumes with its label and turn clock intact.
    // A tool that is still running (toolEndsAt == 0) gets a long window; quiet reasoning
    // (thinking / a finished tool) goes idle much sooner; permission may legitimately sit.
    static let permissionCap: TimeInterval = 7200
    // Backstop only. A cancelled turn is detected deterministically from the transcript's
    // interruption marker (see `interruptedAt`), so this never fires in normal use — it exists
    // purely to eventually clear a true zombie (a turn that died leaving no marker and no process
    // exit, e.g. a fresh session cancelled within a second, before anything was written). It is
    // deliberately generous so a genuinely long silent think is NEVER hidden: liveness counts both
    // hook writes and transcript writes, and this only bites after neither has moved for this long.
    static let workBackstopCap: TimeInterval = 900
    // How long past its last update a session keeps the app alive (so it can quit when the VS
    // Code extension host — whose pid outlives closed sessions — is all that remains).
    static let appHold: TimeInterval = 300
    // Hard reap: delete a file this old no matter what (protects against pid reuse and junk
    // buildup from extension sessions that never fire session-end).
    static let reapCap: TimeInterval = 7200

    static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Modification time of the session's transcript, or 0 if none. The turn writes to its
    /// transcript continuously while alive, so this is a liveness signal that survives the gaps
    /// between hooks; it freezes the instant a turn is interrupted.
    static func transcriptMTime(_ s: SessionSnapshot) -> Double {
        guard !s.transcript.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: s.transcript),
              let m = attrs[.modificationDate] as? Date else { return 0 }
        return m.timeIntervalSince1970
    }

    // How long a just-started turn gets to make its first transcript write. Claude Code persists
    // the user's message within a few seconds of submit (measured ~4s worst case), so a "turn"
    // that has produced NO transcript write this long after starting was killed before it took
    // hold — the very-early Ctrl+C. Genuine turns clear this within seconds and are then immune
    // (their transcript mtime is >= the turn start forever after), no matter how long they think.
    static let firstWriteGrace: TimeInterval = 12

    /// The state a session effectively contributes right now.
    ///
    /// A cancelled turn is caught by `interruptedAt` (deterministic, no timeout). The only time
    /// caps here are generous backstops for a zombie that left no marker: a working session stays
    /// alive as long as EITHER a hook fired or the transcript was written within the backstop, so a
    /// genuinely long silent think — which still streams to its transcript — is never hidden.
    static func effectiveState(_ s: SessionSnapshot, now: Double) -> AgentState {
        func aliveWithin(_ cap: TimeInterval) -> Bool {
            now - max(s.ts, transcriptMTime(s)) <= cap
        }
        // A turn the transcript never acknowledged: it began at startedAt, the grace has passed,
        // and no transcript write has landed at/after the start (an untouched or missing file).
        // That's a Ctrl+C that beat the first flush — dead, not thinking. Self-healing: if a slow
        // first write does land later, the condition stops holding and the island returns.
        func turnNeverTookHold() -> Bool {
            s.startedAt > 0
                && now - s.startedAt > firstWriteGrace
                && transcriptMTime(s) < s.startedAt - 2
        }
        switch s.state {
        case .thinking:
            if turnNeverTookHold() { return .idle }
            return aliveWithin(workBackstopCap) ? .thinking : .idle
        case .tool:
            // A finished tool (toolEndsAt > 0) lingers briefly so fast tools are visible, then the
            // session is back to reasoning — surface that as thinking, not a stale tool label.
            if s.toolEndsAt > 0 && now > s.toolEndsAt {
                return aliveWithin(workBackstopCap) ? .thinking : .idle
            }
            return aliveWithin(workBackstopCap) ? .tool : .idle
        case .permission:
            return (now - s.ts > permissionCap) ? .idle : .permission
        case .done:
            return (now - s.ts <= doneLinger) ? .done : .idle
        case .error:
            return (now - s.ts <= errorLinger) ? .error : .idle
        case .idle:
            return .idle
        }
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// When the session's turn was interrupted, as a unix timestamp, or nil if it wasn't.
    ///
    /// Claude Code writes an interruption entry to the transcript on Ctrl+C / stop / a denied tool,
    /// and fires NO hook for it. So the transcript is the source of truth. We scan the tail for the
    /// newest such entry and return its timestamp; the caller compares it to the turn's start, so a
    /// marker from a PRIOR turn is ignored and a fresh prompt naturally supersedes it. No timeout is
    /// involved — a turn is interrupted the instant the marker lands, and never otherwise.
    static func interruptedAt(_ s: SessionSnapshot) -> Double? {
        guard !s.transcript.isEmpty,
              let fh = FileHandle(forReadingAtPath: s.transcript) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return nil }
        let window: UInt64 = 65536
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // Newest line last; scan backward for the first interruption entry.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard isInterruptLine(line) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = obj["timestamp"] as? String else { continue }
            return (isoFrac.date(from: ts) ?? iso.date(from: ts))?.timeIntervalSince1970 ?? 0
        }
        return nil
    }

    /// Whether one transcript line is a genuine interruption entry. Mirrors the patterns Claude
    /// Code writes (user "[Request interrupted…]" markers, an errored/interrupted tool result),
    /// while a cheap substring pre-check keeps the common non-matching line fast.
    private static func isInterruptLine<S: StringProtocol>(_ line: S) -> Bool {
        if line.contains("Request interrupted by user"),
           let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           (obj["type"] as? String) == "user" {
            let marker = "[Request interrupted by user"
            let c = (obj["message"] as? [String: Any])?["content"]
            if let str = c as? String { return str.hasPrefix(marker) }
            if let blocks = c as? [[String: Any]] {
                return blocks.contains { ($0["type"] as? String) == "text"
                    && (($0["text"] as? String) ?? "").hasPrefix(marker) }
            }
        }
        if line.contains("\"interrupted\":true") { return true }
        return false
    }

    /// Read all files, reap dead ones, and decide what to surface.
    static func evaluate(now: Double = Date().timeIntervalSince1970) -> IslandDecision {
        var live: [SessionSnapshot] = []
        for url in StateStore.listFiles() {
            guard var snap = StateStore.read(url) else { continue }
            // Delete a file only on hard evidence: its process died, or it is ancient. Mere
            // staleness hides the session (display-idle above) but keeps the file, preserving
            // turn-clock continuity for tools that go quiet for a long time.
            let processGone = snap.pid > 0 && !pidAlive(snap.pid)
            if processGone || now - snap.ts > reapCap {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // A turn interrupted (Ctrl+C / stop / denied tool) after it began is dead now — the
            // transcript's interruption marker says so, with no hook and no timeout. Collapse it to
            // idle so the island retracts within a poll; the file stays, and the next prompt (a
            // newer startedAt) revives it. Done once per session here, off the hot path.
            if snap.startedAt > 0, let it = interruptedAt(snap), it >= snap.startedAt - 2 {
                snap.state = .idle
                snap.startedAt = 0
                snap.toolEndsAt = 0
            }
            live.append(snap)
        }

        // Sessions that are visibly doing something — or only went quiet moments ago — keep the
        // app alive. Long-idle files (e.g. closed extension sessions whose host pid persists)
        // don't, so the app can still quit itself.
        let liveCount = live.filter {
            effectiveState($0, now: now) != .idle || now - $0.ts <= appHold
        }.count
        guard !live.isEmpty else { return .hidden }

        // Pick the session most deserving of attention: highest effective priority, then most recent.
        let lead = live.max { a, b in
            let pa = effectiveState(a, now: now).priority
            let pb = effectiveState(b, now: now).priority
            return pa == pb ? a.ts < b.ts : pa < pb
        }!
        let eff = effectiveState(lead, now: now)

        let visible = eff != .idle   // hide while everything rests; the app stays alive
        // When a tool has lingered out to thinking, show "Thinking…" rather than the stale tool label.
        let label = (lead.state == .tool && eff == .thinking) ? "Thinking…" : lead.label
        // The file subtitle only makes sense while actually in a tool (not once it lingers out to thinking).
        let detail = eff == .tool ? lead.detail : ""
        return IslandDecision(
            visible: visible,
            provider: lead.provider,
            state: eff,
            label: label,
            detail: detail,
            startedAt: lead.startedAt,
            liveCount: liveCount,
            forceExpand: eff == .permission
        )
    }
}
